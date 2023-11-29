package means_to_an_end

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:testing"
import "core:thread"

PriceMap :: map[Timestamp]Price

ClientData :: struct {
	price_map: PriceMap,
	endpoint:  net.Endpoint,
	socket:    net.TCP_Socket,
}

Timestamp :: distinct u32

Price :: distinct i32

Message :: union {
	Insert,
	Query,
}

Insert :: struct {
	timestamp: Timestamp,
	price:     Price,
}

Query :: struct {
	minimum_time: Timestamp,
	maximum_time: Timestamp,
}

Response :: distinct i32

main :: proc() {
	context.logger = log.create_console_logger()

	if len(os.args) < 2 {
		fmt.printf("Usage: %s <port>", os.args[0])

		os.exit(1)
	}

	port_string := os.args[1]
	port, port_parse_ok := strconv.parse_int(port_string, 10)
	if !port_parse_ok {
		fmt.printf("Invalid port: '%s'", port_string)

		os.exit(1)
	}

	endpoint := net.Endpoint {
		address = net.IP4_Address([4]u8{0, 0, 0, 0}),
		port    = port,
	}

	listen_socket, listen_error := net.listen_tcp(endpoint)
	if listen_error != nil {
		fmt.printf("Error listening on port %d: %v", port, listen_error)

		os.exit(1)
	}

	log.infof("Listening on port %d", port)

	thread_pool: thread.Pool
	thread.pool_init(&thread_pool, context.allocator, 100)
	thread.pool_start(&thread_pool)

	for {
		client_socket, client_endpoint, accept_error := net.accept_tcp(listen_socket)
		if accept_error != nil {
			log.errorf("Error accepting connection: %v", accept_error)

			continue
		}
		log.debugf("Accepted connection: %d (%v)", client_socket, client_endpoint)

		client_arena: virtual.Arena
		arena_allocator_error := virtual.arena_init_growing(&client_arena, 1 * mem.Kilobyte)
		if arena_allocator_error != nil {
			log.errorf("Error initializing client arena: %v", arena_allocator_error)

			net.close(client_socket)
			continue
		}
		client_allocator := virtual.arena_allocator(&client_arena)
		client_data, client_data_allocator_error := new(ClientData, client_allocator)
		if client_data_allocator_error != nil {
			log.errorf("Error allocating client data: %v", client_data_allocator_error)

			net.close(client_socket)
			continue
		}
		client_data.endpoint = client_endpoint
		client_data.socket = client_socket
		thread.pool_add_task(&thread_pool, client_allocator, handle_client, client_data)
	}
}

handle_client :: proc(t: thread.Task) {
	client_data := cast(^ClientData)t.data
	context.logger = log.create_console_logger(ident = fmt.tprintf("%v", client_data.endpoint))
	price_map, client_data_allocator_error := make_map(map[Timestamp]Price, 0, t.allocator)
	if client_data_allocator_error != nil {
		log.errorf("Error allocating client price map: %v", client_data_allocator_error)

		net.close(client_data.socket)
	}

	client_data.price_map = price_map

	log.debugf("Handling client: %v (%v)", client_data.endpoint, client_data)

	for {
		recv_buffer: [9]byte
		message, done, receive_error := receive_message(client_data.socket, recv_buffer[:])
		if receive_error != nil {
			log.errorf("Error receiving message: %v", receive_error)

			break
		}
		if done {
			log.infof("Client disconnected: %v", client_data.endpoint)

			break
		}

		send_buffer: [4]byte
		outgoing_message := handle_message(message, &client_data.price_map, send_buffer[:])
		if outgoing_message != nil {
			log.debugf("Sending message: %s (%d)", outgoing_message, transmute(i32be)send_buffer)
			sent_bytes, send_error := net.send_tcp(client_data.socket, outgoing_message)
			if send_error != nil {
				log.errorf("Error sending message: %v", send_error)

				break
			}
			if sent_bytes != len(outgoing_message) {
				log.errorf(
					"Error sending message: sent %d bytes, expected to send %d bytes",
					sent_bytes,
					len(outgoing_message),
				)

				break
			}
		}
	}

	net.close(client_data.socket)
}

handle_message :: proc(
	message: Message,
	price_map: ^PriceMap,
	send_buffer: []byte,
) -> (
	outgoing_message: []byte,
) {
	switch m in message {
	case Insert:
		price_map[m.timestamp] = m.price

		return nil
	case Query:
		mean_price: i32be = mean(price_map, m.minimum_time, m.maximum_time)
		mean_price_bytes: [4]byte = transmute([4]byte)mean_price
		mean_price_bytes_slice: []byte = mean_price_bytes[:]
		copy_slice(send_buffer, mean_price_bytes_slice)

		return send_buffer
	}

	return nil
}

mean :: proc(
	price_map: ^PriceMap,
	minimum_time: Timestamp,
	maximum_time: Timestamp,
) -> (
	mean_price: i32be,
) {
	sum := 0
	count := 0
	for timestamp, price in price_map {
		if timestamp >= minimum_time && timestamp <= maximum_time {
			sum += int(price)
			count += 1
		}
	}

	if count == 0 {
		return 0
	}

	return i32be(sum / count)
}

receive_message :: proc(
	socket: net.TCP_Socket,
	buffer: []byte,
) -> (
	message: Message,
	done: bool,
	error: net.Network_Error,
) {
	bytes_received := 0
	for bytes_received < len(buffer) {
		n, recv_error := net.recv_tcp(socket, buffer[bytes_received:])
		if recv_error == net.TCP_Recv_Error.Timeout {
			bytes_received += n

			continue
		} else if recv_error != nil {
			log.errorf("Error receiving message: %v", recv_error)

			return nil, true, recv_error
		}

		// if bytes_received == 0 {
		// 	done = true
		// }

		bytes_received += n
	}

	return parse_message(buffer), done, nil
}

parse_message :: proc(buffer: []byte) -> (message: Message) {
	identifying_byte := buffer[0]
	switch identifying_byte {
	case 'I':
		timestamp_bytes := [4]byte{buffer[1], buffer[2], buffer[3], buffer[4]}
		timestamp := transmute(u32be)timestamp_bytes
		price_bytes := [4]byte{buffer[5], buffer[6], buffer[7], buffer[8]}
		price := transmute(i32be)price_bytes
		message = Insert {
			timestamp = Timestamp(timestamp),
			price     = Price(price),
		}

	case 'Q':
		minimum_time_bytes := [4]byte{buffer[1], buffer[2], buffer[3], buffer[4]}
		minimum_time := transmute(u32be)minimum_time_bytes
		maximum_time_bytes := [4]byte{buffer[5], buffer[6], buffer[7], buffer[8]}
		maximum_time := transmute(u32be)maximum_time_bytes
		message = Query {
			minimum_time = Timestamp(minimum_time),
			maximum_time = Timestamp(maximum_time),
		}
	}

	return message
}

@(test, private = "package")
test_parse_message :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()

	test_bytes_1 := [9]byte{'I', 0, 0, 0x30, 0x39, 0, 0, 0, 0x65}
	test_bytes_2 := [9]byte{'I', 0, 0, 0x30, 0x3a, 0, 0, 0, 0x66}
	test_bytes_3 := [9]byte{'I', 0, 0, 0x30, 0x3b, 0, 0, 0, 0x64}
	test_bytes_4 := [9]byte{'I', 0, 0, 0xa0, 0, 0, 0, 0, 0x05}

	test_message_1 := parse_message(test_bytes_1[:])
	testing.expect_value(
		t,
		test_message_1,
		Insert{timestamp = Timestamp(12345), price = Price(101)},
	)

	test_message_2 := parse_message(test_bytes_2[:])
	testing.expect_value(
		t,
		test_message_2,
		Insert{timestamp = Timestamp(12346), price = Price(102)},
	)

	test_message_3 := parse_message(test_bytes_3[:])
	testing.expect_value(
		t,
		test_message_3,
		Insert{timestamp = Timestamp(12347), price = Price(100)},
	)

	test_message_4 := parse_message(test_bytes_4[:])
	testing.expect_value(t, test_message_4, Insert{timestamp = Timestamp(40960), price = Price(5)})
}

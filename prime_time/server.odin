package prime_time

import "core:bytes"
import c "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:sys/unix"
import "core:testing"

NAME :: "PrimeTime"

main :: proc() {
	context.logger = log.create_console_logger()

	if (len(os.args) != 2) {
		fmt.printf("Usage: %s <port>\n", os.args[0])

		os.exit(1)
	}

	port, port_parsed := strconv.parse_u64(os.args[1], 10)
	if !port_parsed {
		fmt.printf("Invalid port: %s\n", os.args[1])

		os.exit(1)
	}

	fmt.printf("Starting %s on port %d\n", NAME, port)

	endpoint, endpoint_parsed := net.parse_endpoint("0.0.0.0")
	if !endpoint_parsed {
		fmt.printf("Failed to parse endpoint\n")

		os.exit(1)
	}
	endpoint.port = int(port)

	listen_socket, listen_error := net.listen_tcp(endpoint)
	if listen_error != nil {
		fmt.printf("Failed to listen on port %d: %v\n", port, listen_error)

		os.exit(1)
	}

	clients := make(map[net.TCP_Socket]os.pollfd, 0)

	clients_to_remove, fds_to_remove_alloc_error := make([dynamic]net.TCP_Socket, 0, 1024)
	if fds_to_remove_alloc_error != nil {
		fmt.printf("Failed to allocate clients_to_remove: %v\n", fds_to_remove_alloc_error)

		os.exit(1)
	}

	listen_fds := [1]os.pollfd{os.pollfd{fd = c.int(listen_socket), events = unix.POLLIN}}
	recv_buffer: [50 * mem.Kilobyte]byte
	send_buffer: [8 * mem.Kilobyte]byte
	response_buffer: [8 * mem.Kilobyte]byte
	for {
		poll_result, poll_errno := os.poll(listen_fds[:], 10)
		if poll_result == -1 || poll_errno != os.ERROR_NONE {
			fmt.printf("Failed to poll listen FDs: %d\n", poll_errno)

			os.exit(1)
		}

		if poll_result > 0 {
			client_socket, client_endpoint, accept_error := net.accept_tcp(listen_socket)
			if accept_error != nil {
				log.errorf("Failed to accept client: %v", accept_error)
			}

			log.infof("Accepted client %v (socket: %d)", client_endpoint, client_socket)

			pollfd := os.pollfd {
				fd     = c.int(client_socket),
				events = unix.POLLIN,
			}
			clients[client_socket] = pollfd
		}

		_fds: []os.pollfd
		alloc_error: mem.Allocator_Error
		_fds, alloc_error = slice.map_values(clients)
		if alloc_error != nil {
			log.errorf("Failed to allocate for map values: _fds: %v", alloc_error)

			continue
		}
		defer delete(_fds)
		poll_result, poll_errno = os.poll(_fds, 50)
		if poll_result == -1 || poll_errno != os.ERROR_NONE {
			log.errorf("Failed to poll client FDs: %d", poll_errno)

			continue
		}

		for fd in _fds {
			socket := net.TCP_Socket(fd.fd)
			clients[socket] = fd
		}

		clear(&clients_to_remove)
		if poll_result > 0 {
			for socket, fd in clients {
				if fd.revents & unix.POLLIN != 0 {
					message, closed := receive_message(recv_buffer[:], fd.fd)
					if closed {
						net.close(net.TCP_Socket(fd.fd))

						continue
					}

					valid_messages, validation_error := validate_messages(message)
					defer delete(valid_messages)
					if validation_error != nil {
						log.errorf("Failed to validate message: %v", validation_error)

						copy(send_buffer[:], "invalid")
						net.send_tcp(net.TCP_Socket(fd.fd), send_buffer[:len("invalid")])

						net.close(net.TCP_Socket(fd.fd))
						log.debugf("adding fd %d for removal because of validation error", socket)
						append(&clients_to_remove, socket)

						continue
					}

					for valid_message, i in valid_messages {
						outgoing_message, response_allocation_error := handle_request(
							response_buffer[:],
							valid_message,
						)
						if response_allocation_error != nil {
							log.errorf(
								"Failed to allocate response: %v",
								response_allocation_error,
							)

							net.close(net.TCP_Socket(fd.fd))

							log.debugf("adding %d for removal because of send error", socket)
							append(&clients_to_remove, socket)

							continue
						}

						bytes_to_send := len(outgoing_message)
						bytes_sent := 0
						for bytes_sent < bytes_to_send {
							slice_to_send := outgoing_message[bytes_sent:]
							copy(send_buffer[:], slice_to_send)
							n, send_error := net.send_tcp(net.TCP_Socket(fd.fd), slice_to_send)
							if send_error != nil {
								log.errorf("Failed to send response: %v", send_error)

								net.close(net.TCP_Socket(fd.fd))
							}

							bytes_sent += n
						}
						net.send_tcp(net.TCP_Socket(fd.fd), []byte{'\n'})
					}
				}
			}

			for client in clients_to_remove {
				delete_key(&clients, client)
			}
		}
	}
}

Response :: struct {
	method: string,
	prime:  bool,
}

handle_request :: proc(b: []byte, r: Request) -> (response: []byte, error: mem.Allocator_Error) {
	buffer_arena: virtual.Arena
	virtual.arena_init_buffer(&buffer_arena, b) or_return
	buffer_allocator := virtual.arena_allocator(&buffer_arena)

	number_is_prime := is_prime(r.number)

	response_value := Response {
		method = "isPrime",
		prime  = number_is_prime,
	}
	json_data, _ := json.marshal(response_value, allocator = buffer_allocator)

	return json_data, .None
}

is_prime :: proc(n: Number) -> bool {
	_, is_float := n.(f64)
	if is_float {
		return false
	}

	n := int(n.(i64))

	if n <= 1 {
		return false
	}

	if n == 2 {
		return true
	}

	if n % 2 == 0 {
		return false
	}

	for i := 3; i < int(math.floor(math.sqrt(f32(n)))); i += 2 {
		if n % i == 0 {
			return false
		}
	}

	return true
}

@(test, private = "package")
test_is_prime :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()

	cases := map[i64]bool {
		157813 = true,
		800399 = true,
		863833 = true,
		569577 = false,
	}

	for x, expected in cases {
		actual := is_prime(x)
		log.debugf("is_prime(%d) == %v, expecting %v", x, actual, expected)

		testing.expect(t, actual == expected, fmt.tprintf("is_prime(%d) == %v", x, expected))
	}

	float_cases := map[f64]bool {
		157813.0                                                                                              = false,
		800399.0                                                                                              = false,
		3.141592653589793238462643383279502884197169399375105820974944592307816406286208998628034825342117067 = false,
	}

	for f, expected in float_cases {
		actual := is_prime(f)
		log.debugf("is_prime(%f) == %v, expecting %v", f, actual, expected)

		testing.expect(t, actual == expected, fmt.tprintf("is_prime(%f) == %v", f, expected))
	}
}

Request :: struct {
	number: Number,
}

Number :: union {
	i64,
	f64,
}

Validation_Error :: union {
	json.Error,
	mem.Allocator_Error,
	Invalid_Json_Type,
	Missing_Method,
	Missing_Is_Prime,
	Invalid_Is_Prime_Value,
}

Invalid_Json_Type :: struct {}

Invalid_Is_Prime_Value :: struct {}

Missing_Method :: struct {}
Missing_Is_Prime :: struct {}

validate_messages :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	valid_messages: [dynamic]Request,
	validation_error: Validation_Error,
) {
	_valid_messages := make([dynamic]Request, 0, 0, allocator) or_return

	split_messages := bytes.split(data, []byte{'\n'}, allocator)
	for message in split_messages {
		json_value := json.parse(message, parse_integers = true) or_return
		object, is_object := json_value.(json.Object)
		if !is_object {
			return nil, Invalid_Json_Type{}
		}

		method, method_exists := object["method"]
		method_as_string, method_is_string := method.(json.String)
		if !method_exists || !method_is_string || method_as_string != "isPrime" {
			return nil, Missing_Method{}
		}

		number_value, number_exists := object["number"]
		if !number_exists {
			return nil, Missing_Is_Prime{}
		}

		number_as_integer, number_is_integer := number_value.(json.Integer)
		number_as_float, number_is_float := number_value.(json.Float)

		if !number_is_integer && !number_is_float {
			return nil, Invalid_Is_Prime_Value{}
		}

		number := number_is_integer ? Number(number_as_integer) : Number(number_as_float)

		append(&_valid_messages, Request{number = number})
	}

	return _valid_messages, nil
}

receive_message :: proc(b: []byte, fd: c.int) -> (received_bytes: []byte, closed: bool) {
	bytes_received := 0
	loop: for {
		n, recv_error := net.recv_tcp(net.TCP_Socket(fd), b[bytes_received:])
		if n == 0 {
			return nil, true
		}
		bytes_received += n
		last_character := b[bytes_received - 1]
		switch {
		case last_character == '\n':
			received_bytes = b[:bytes_received - 1]
			break loop
		case recv_error == net.TCP_Recv_Error.Timeout:
			continue
		case recv_error != nil:
			log.errorf("Failed to receive message: %v", recv_error)
			return nil, true
		}
	}

	return received_bytes, false
}

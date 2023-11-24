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

	_fds, pollfds_alloc_error := make([dynamic]os.pollfd, 0, 1024)
	if pollfds_alloc_error != nil {
		fmt.printf("Failed to allocate pollfds: %v\n", pollfds_alloc_error)

		os.exit(1)
	}

	listen_fds := [1]os.pollfd{os.pollfd{fd = c.int(listen_socket), events = unix.POLLIN}}
	recv_buffer: [8 * mem.Kilobyte]byte
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

			log.debugf("Accepted client %v", client_endpoint)

			pollfd := os.pollfd {
				fd     = c.int(client_socket),
				events = unix.POLLIN,
			}
			append(&_fds, pollfd)
		}

		poll_result, poll_errno = os.poll(_fds[:], 50)
		if poll_result == -1 || poll_errno != os.ERROR_NONE {
			log.errorf("Failed to poll client FDs: %d", poll_errno)

			continue
		}

		if poll_result > 0 {
			for fd, fd_index in _fds[:] {
				if fd.revents & unix.POLLIN != 0 {
					message, closed := receive_message(&_fds, fd_index, recv_buffer[:], fd.fd)
					if closed {
						net.close(net.TCP_Socket(fd.fd))

						continue
					}
					log.debugf("Received message: '%s'", message)

					valid_message, validation_error := validate_message(message)
					if validation_error != nil {
						log.errorf("Failed to validate message: %v", validation_error)

						copy(send_buffer[:], "invalid")
						net.send_tcp(net.TCP_Socket(fd.fd), send_buffer[:len("invalid")])

						net.close(net.TCP_Socket(fd.fd))
						ordered_remove(&_fds, fd_index)

						continue
					}

					outgoing_message, response_allocation_error := handle_request(
						response_buffer[:],
						valid_message,
					)
					if response_allocation_error != nil {
						log.errorf("Failed to allocate response: %v", response_allocation_error)

						net.close(net.TCP_Socket(fd.fd))
						ordered_remove(&_fds, fd_index)

						continue
					}

					log.debugf("Sending response: '%s'", outgoing_message)
					bytes_to_send := len(outgoing_message)
					bytes_sent := 0
					for bytes_sent < bytes_to_send {
						slice_to_send := outgoing_message[bytes_sent:]
						copy(send_buffer[:], slice_to_send)
						n, send_error := net.send_tcp(net.TCP_Socket(fd.fd), slice_to_send)
						log.debugf("Sent %d bytes: '%s'", n, slice_to_send)
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
	log.debugf("Response: %v", response_value)
	json_data, _ := json.marshal(response_value, allocator = buffer_allocator)

	return json_data, .None
}

is_prime :: proc(n: Number) -> bool {
	_, is_float := n.(f64)
	if is_float {
		return false
	}

	n := int(n.(i64))

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
	Invalid_Json_Type,
	Missing_Method,
	Missing_Is_Prime,
	Invalid_Is_Prime_Value,
}

Invalid_Json_Type :: struct {
	type: typeid,
}

Invalid_Is_Prime_Value :: struct {
	type: typeid,
}

Missing_Method :: struct {}
Missing_Is_Prime :: struct {}

typeid_from_value :: proc(value: json.Value) -> typeid {
	switch v in value {
	case json.Null:
		return nil
	case json.Boolean:
		return bool
	case json.Integer:
		return int
	case json.Float:
		return f32
	case json.String:
		return string
	case json.Array:
		return typeid_from_value(v)
	case json.Object:
		return map[string]json.Value
	}

	return nil
}

validate_message :: proc(
	message: []byte,
) -> (
	valid_message: Request,
	validation_error: Validation_Error,
) {
	json_value := json.parse(message) or_return
	object, is_object := json_value.(json.Object)
	if !is_object {
		return Request{}, Invalid_Json_Type{type = typeid_from_value(json_value)}
	}

	method, method_exists := object["method"]
	method_as_string, method_is_string := method.(json.String)
	if !method_exists || !method_is_string || method_as_string != "isPrime" {
		return Request{}, Missing_Method{}
	}

	number_value, number_exists := object["number"]
	if !number_exists {
		return Request{}, Missing_Is_Prime{}
	}

	number_as_integer, number_is_integer := number_value.(json.Integer)
	number_as_float, number_is_float := number_value.(json.Float)

	if !number_is_integer && !number_is_float {
		return Request{}, Invalid_Is_Prime_Value{type = typeid_from_value(number_value)}
	}

	number := number_is_integer ? Number(number_as_integer) : Number(number_as_float)

	return Request{number = number}, nil
}

receive_message :: proc(
	fds: ^[dynamic]os.pollfd,
	fd_index: int,
	b: []byte,
	fd: c.int,
) -> (
	message: []byte,
	closed: bool,
) {
	bytes_received, recv_error := net.recv_tcp(net.TCP_Socket(fd), b)
	if recv_error != nil {
		log.errorf("Failed to recv: %v", recv_error)

		return nil, true
	}
	if bytes_received == 0 {
		log.debugf("Client %d closed connection", fd)
		ordered_remove(fds, fd_index)
		net.close(net.TCP_Socket(fd))

		return nil, true
	}

	received_slice := b[:bytes_received]
	newline_index := bytes.index_byte(received_slice, '\n')

	return received_slice[:newline_index], false
}

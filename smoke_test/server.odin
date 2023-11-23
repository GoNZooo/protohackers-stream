package smoke_test

import c "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:sys/unix"

NAME :: "SmokeTest"

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
			log.debugf("poll_result=%d", poll_result)
		}

		if poll_result > 0 {
			for fd, fd_index in _fds[:] {
				if fd.revents & unix.POLLIN != 0 {
					log.debugf("fd.revents=%02x", fd.revents)
					bytes_received, recv_error := net.recv_tcp(
						net.TCP_Socket(fd.fd),
						recv_buffer[:],
					)
					if recv_error != nil {
						log.errorf("Failed to recv: %v", recv_error)

						break
					}
					if bytes_received == 0 {
						log.debugf("Client closed connection")
						ordered_remove(&_fds, fd_index)
						net.close(net.TCP_Socket(fd.fd))

						break
					}

					received := recv_buffer[:bytes_received]
					log.debugf("Received %d bytes: '%s'", bytes_received, received)

					bytes_sent := 0
					for bytes_sent < bytes_received {
						send_slice := recv_buffer[bytes_sent:bytes_received]
						n, send_error := net.send_tcp(net.TCP_Socket(fd.fd), send_slice)
						log.debugf("Sent %d bytes: '%s'", n, send_slice)
						if send_error != nil {
							log.errorf("Failed to send: %v", send_error)

							break
						}

						bytes_sent += n
					}
				}
			}
		}
	}
}

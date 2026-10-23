# Tagged HTTP routes

A small `std::net::http` server whose routes are declared with tags (YMI-223):

- `#[get ("/path")]` and `#[post ("/path")]` declare only a `self` overload. Each site runs it once
  before `main`, and it appends `(path, method, function)` to the global `ROUTES`.
- `#[logged]` declares an `apply` overload. It replaces the function with a wrapper that logs the
  method, the URL and the response code. It is the innermost tag of each site, so `get` and `post`
  register the logged function.
- `main` only hands `ROUTES` to the `HttpServer`, so the server never names a route.

```sh
uv run preview --no-midgard        # a preview gyc with the tag constructors (bootstrap YMI-230)
uv run exec examples/tagged_http/main.yr -o build/examples/tagged_http
./build/examples/tagged_http 8080  # the port, 8080 by default
```

```sh
$ curl 127.0.0.1:8080/
Hello from a tagged route
$ curl 127.0.0.1:8080/routes
GET /
GET /routes
POST /echo
$ curl -X POST -d 'ping from curl' 127.0.0.1:8080/echo
ping from curl
```

Unknown paths get 404, and a known path with the wrong method gets 405.

## Known midgard limits (1.16.x)

The `HttpRequest` parser has two bugs, both answered with a 400:

- **`Host` header:** the host part must be an IP address. `curl localhost:8080` sends
  `Host: localhost:8080` and is rejected, so use `127.0.0.1`.
- **Short header values:** `trim` drops a value of one character, so a body of 1 to 9 bytes
  (`Content-Length: 6`) is rejected. Use a body of 10 bytes or more.

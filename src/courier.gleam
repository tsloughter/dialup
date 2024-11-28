// IMPORTS ---------------------------------------------------------------------

import gleam/dynamic
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/result
import gleam/uri.{type Uri}
import lustre/effect.{type Effect}

@target(erlang)
import gleam/erlang/process
@target(erlang)
import gleam/httpc

@target(javascript)
import gleam/fetch
@target(javascript)
import gleam/javascript/promise

// TYPES -----------------------------------------------------------------------

/// A request might fail for a number of reasons. This type is a high-level
/// wrapper over the different kinds of errors that might occur when creating and
/// executing a HTTP request.
///
pub type Error {
  ///
  BadBody
  /// This error can happen when the URL provided to the `get` or `post`
  BadUrl(String)
  HttpError(Response(String))
  JsonError(json.DecodeError)
  NetworkError
  UnhandledResponse(Response(String))
}

/// A handler is a function that knows how to take the result of a HTTP request
/// and turn it into a message that can be dispatched back to your `update`
/// function. Courier exposess a number of handlers for common scenarios:
///
/// - [`expect_json`](#expect_json) to ensure a response's content-type is
///   `"application/json"` and run a JSON decoder on that body.
///
/// - [`expect_text`](#expect_text) to ensure a response's content-type is
///   `"text/plain"` and return the body as a string.
///
/// - [`expect_ok_response`](#expect_ok_response) to handle any response with a
///   2xx status code.
///
/// - [`expect_any_response`](#expect_any_response) to handle any HTTP response,
///   including 4xx and 5xx errors.
///
pub opaque type Handler(msg) {
  Handler(run: fn(Result(Response(String), Error)) -> msg)
}

// HANDLERS --------------------------------------------------------------------

/// A handler that runs a JSON decoder on a response body and returns the result
/// as a message. This handler will check the following conditions:
///
/// - The response status code is `2xx`.
///
/// - The response content-type is `"application/json"`
///
/// - The response body can be decoded using the provided JSON decoder
///
/// If any of these conditions are not met, an `Error` will be returned instead.
/// The specific error will depend on which condition failed:
///
/// - `4xx` and `5xx` status codes will return `HttpError`
///
/// - Other non `2xx` status codes will return `UnhandledResponse`
///
/// - A missing or incorrect `content-type` header will return `UnhandledResponse`
///
/// - A JSON decoding error will return `JsonError`
///
/// **Note**: if you need more advanced handling of the request body directly, you
/// should use the more-general [`expect_ok_response`](#expect_ok_response) or
/// [`expect_any_response`](#expect_any_response) handlers.
///
pub fn expect_json(
  decoder: dynamic.Decoder(a),
  handler: fn(Result(a, Error)) -> msg,
) -> Handler(msg) {
  use result <- expect_json_response

  result
  |> result.then(decode_json_body(_, decoder))
  |> handler
}

fn expect_json_response(
  handler: fn(Result(Response(String), Error)) -> msg,
) -> Handler(msg) {
  use result <- expect_ok_response

  handler({
    use response <- result.try(result)

    case response.get_header(response, "content-type") {
      Ok("application/json") -> Ok(response)
      _ -> Error(UnhandledResponse(response))
    }
  })
}

/// Handle the body of a plain text response. This handler will check the
/// following conditions:
///
/// - The response status code is `2xx`.
///
/// - The response content-type is `"text/plain"`
///
/// If any of these conditions are not met, an `Error` will be returned instead.
/// The specific error will depend on which condition failed:
///
/// - `4xx` and `5xx` status codes will return `HttpError`
///
/// - Other non `2xx` status codes will return `UnhandledResponse`
///
/// - A missing or incorrect `content-type` header will return `UnhandledResponse`
///
/// **Note**: if you need more advanced handling of the request body directly, you
/// should use the more-general [`expect_ok_response`](#expect_ok_response) or
/// [`expect_any_response`](#expect_any_response) handlers.
///
pub fn expect_text(handler: fn(Result(String, Error)) -> msg) -> Handler(msg) {
  use result <- expect_text_response

  result
  |> result.map(fn(response) { response.body })
  |> handler
}

fn expect_text_response(
  handler: fn(Result(Response(String), Error)) -> msg,
) -> Handler(msg) {
  use result <- expect_ok_response

  handler({
    use response <- result.try(result)

    case response.get_header(response, "content-type") {
      Ok("text/plain") -> Ok(response)
      _ -> Error(UnhandledResponse(response))
    }
  })
}

/// Handle any response with a `2xx` status code. This handler will return an
/// `Error` if the response status code is not in the `2xx` range. The specific
/// error will depend on the status code:
///
/// - `4xx` and `5xx` status codes will return `HttpError`
///
/// - Other non `2xx` status codes will return `UnhandledResponse`
///
/// **Note**: if you need to handle HTTP responses with different status codes,
/// you should use the more-general [`expect_any_response`](#expect_any_response)
/// handler.
///
pub fn expect_ok_response(
  handler: fn(Result(Response(String), Error)) -> msg,
) -> Handler(msg) {
  use result <- Handler

  handler({
    use response <- result.try(result)

    case response.status {
      code if code >= 200 && code < 300 -> Ok(response)
      code if code >= 400 && code < 600 -> Error(HttpError(response))
      _ -> Error(UnhandledResponse(response))
    }
  })
}

/// Handle any HTTP response, regardless of status code. Your custom handler will
/// still have to handle potential errors such as network errors or malformed
/// responses.
///
/// It is uncommon to need a handler this low-level, instead you can consider the
/// following more-specific handlers:
///
/// - [`expect_ok_response`](#expect_ok_response) to handle any response with a
///   `2xx` status code.
///
/// - [`expect_json`](#expect_json) to handle responses from JSON apis
///
pub fn expect_any_response(
  handler: fn(Result(Response(String), Error)) -> msg,
) -> Handler(msg) {
  Handler(handler)
}

// REQUESTS --------------------------------------------------------------------

/// A convenience function to send a `GET` request to a URL and decode the
///
/// **Note**: if you need more control over the kind of request being sent, for
/// example to set additional headers or use a different HTTP method, you should
/// use the more-general [`send`](#send) function insteaed.
///
pub fn get(url: String, handler: Handler(msg)) -> Effect(msg) {
  case to_uri(url) {
    Ok(uri) -> {
      send(
        Request(
          method: http.Get,
          headers: [],
          body: "",
          scheme: to_scheme(uri.scheme),
          host: uri.host |> option.unwrap(""),
          port: uri.port,
          path: uri.path,
          query: uri.query,
        ),
        handler,
      )
    }

    Error(err) ->
      effect.from(fn(dispatch) {
        Error(err)
        |> handler.run
        |> dispatch
      })
  }
}

/// A convenience function for sending a POST request with a JSON body and handle
/// the response with a handler function. This will automatically set the
/// `content-type` header to `application/json` and handle requests to relative
/// URLs if this effect is running in a browser.
///
/// **Note**: if you need more control over the kind of request being sent, for
/// example to set additional headers or use a different HTTP method, you should
/// use the more-general [`send`](#send) function insteaed.
///
pub fn post(url: String, body: Json, handler: Handler(msg)) -> Effect(msg) {
  case to_uri(url) {
    Ok(uri) -> {
      send(
        Request(
          method: http.Post,
          headers: [#("content-type", "application/json")],
          body: json.to_string(body),
          scheme: to_scheme(uri.scheme),
          host: uri.host |> option.unwrap(""),
          port: uri.port,
          path: uri.path,
          query: uri.query,
        ),
        handler,
      )
    }

    Error(err) ->
      effect.from(fn(dispatch) {
        Error(err)
        |> handler.run
        |> dispatch
      })
  }
}

/// Send a [`Request`](https://hexdocs.pm/gleam_http/gleam/http/request.html#Request)
/// and dispatch a message back to your `update` function when the response is
/// handled.
///
/// For simple requests, you can use the more-convenient [`get`](#get) and
/// [`post`](#post) functions instead.
///
/// **Note**: On the **JavaScript** target this will use the `fetch` API. Make
/// sure you have a polyfill for it if you need to support older browsers or
/// server-side runtimes that don't have it.
///
/// **Note**: On the **Erlang** target this will use the `httpc` module. Each
/// request will start a new _unlinked_ process to handle the request.
///
pub fn send(request: Request(String), handler: Handler(msg)) -> Effect(msg) {
  do_send(request, handler)
}

@target(erlang)
fn do_send(request: Request(String), handler: Handler(msg)) -> Effect(msg) {
  use dispatch <- effect.from

  process.start(
    running: fn() {
      httpc.send(request)
      |> result.map_error(fn(error) {
        case error {
          httpc.InvalidUtf8Response -> BadBody
          httpc.FailedToConnect(_, _) -> NetworkError
        }
      })
      |> handler.run
      |> dispatch
    },
    linked: True,
  )

  Nil
}

@target(javascript)
fn do_send(request: Request(String), handler: Handler(msg)) -> Effect(msg) {
  use dispatch <- effect.from

  fetch.send(request)
  |> promise.try_await(fetch.read_text_body)
  |> promise.map(result.map_error(_, fn(error) {
    case error {
      fetch.NetworkError(_) -> NetworkError
      fetch.UnableToReadBody -> BadBody
      fetch.InvalidJsonBody -> BadBody
    }
  }))
  |> promise.map(handler.run)
  |> promise.tap(dispatch)

  Nil
}

// UTILS -----------------------------------------------------------------------

fn decode_json_body(
  response: Response(String),
  decoder: dynamic.Decoder(a),
) -> Result(a, Error) {
  response.body
  |> json.decode(decoder)
  |> result.map_error(JsonError)
}

fn to_uri(uri_string: String) -> Result(Uri, Error) {
  case uri_string {
    "./" <> _ | "/" <> _ -> parse_relative_uri(uri_string)
    _ -> uri.parse(uri_string)
  }
  |> result.map_error(fn(_) { BadUrl(uri_string) })
}

fn to_scheme(scheme: Option(String)) -> http.Scheme {
  case scheme {
    option.Some("http") -> http.Http
    option.Some("https") -> http.Https
    _ -> http.Https
  }
}

/// The standard library [`uri.parse`](https://hexdocs.pm/gleam_stdlib/0.45.0/gleam/uri.html#parse)
/// function does not support relative URIs. When running in the browser, however,
/// we have enough information to resolve relative URIs into complete ones!
///
/// This function will always fail when running on the server, but in the browser
/// it will resolve relative URIs based on the current page's URL
///
@external(javascript, "./courier.ffi.mjs", "from_relative_url")
pub fn parse_relative_uri(_uri_string: String) -> Result(Uri, Nil) {
  Error(Nil)
}

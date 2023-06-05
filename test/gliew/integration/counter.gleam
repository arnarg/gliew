import gleam/int
import gleam/string
import gleam/option.{None, Some}
import gleam/http.{Get}
import gleam/http/request
import gleam/erlang/process.{Subject}
import nakai/html
import nakai/html/attrs
import gliew
// This is only here for this example.
// It implements an actor that keeps an
// incrementing counter and can be
// subscribed to.
import gliew/integration/counter_impl.{
  CounterMessage, get_current, start_counter, subscribe,
}

//        //
// Server //
//        //

pub fn main() {
  // Start anything that will be needed by the handlers.
  // In this case we start an actor that simply increments
  // a counter (starting at 0).
  // You can subscribe to the counter to be notified every
  // time it increments.
  let assert Ok(count_actor) = start_counter()

  // Start the gliew server.
  // This is a thin wrapper around mist which handles
  // rendering your views and starting workers for
  // live connections.
  let assert Ok(_) =
    gliew.serve(
      8080,
      fn(req) {
        case req.method, request.path_segments(req) {
          Get, ["counter"] -> counter(count_actor)
          _, _ -> home()
        }
      },
    )
  process.sleep_forever()
}

// A simple view.
fn home() {
  // Makes the function a simple view.
  use <- gliew.view

  html.div_text([], "Hello gleam!")
}

// A live view that shows a live updating counter.
fn counter(count_actor: Subject(CounterMessage)) {
  // Makes the function a live view.
  // The second parameter passed to `gliew.live_view`
  // will be passed to the mount function (first parameter)
  // when the view is mounted (i.e. the client connects
  // back to the server to get live updates).
  //
  // The returned value is of type `Option(a)` where
  // `a` is the type in the Subject returned by mount.
  use assign <- gliew.live_view(mount: counter_mount, with: count_actor)

  let counter = case assign {
    // View has been mounted and we want to use the
    // "live" value that was setup in the mount function.
    Some(counter) -> counter
    // View is being rendered on the server before
    // the client has made a connection back to the server.
    // Here we contact the count_actor to get the current
    // value.
    None -> get_current(count_actor)
  }

  // Return the HTML of the view.
  html.div(
    [
      attrs.style(
        [
          "display: flex", "flex-direction: column", "justify-content: center",
          "align-items: center", "row-gap: 1em", "height: 100vh",
        ]
        |> string.join(";"),
      ),
    ],
    [
      html.div_text([attrs.style("font-size: x-large")], "Counter is at"),
      html.div_text(
        [attrs.style("font-size: xx-large")],
        int.to_string(counter),
      ),
    ],
  )
}

// A mount function that runs once the client connects through
// a websocket.
// This should be used to subscribe to whatever data that should
// be returned to the render function and return the subject.
fn counter_mount(count_actor: Subject(CounterMessage)) {
  // Create a new subject.
  let subject = process.new_subject()

  // Subscribe to counter.
  subscribe(count_actor, subject)

  // Return an assign with the subject.
  gliew.assign(subject)
}

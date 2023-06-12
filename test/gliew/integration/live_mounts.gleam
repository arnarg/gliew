import gleam/int
import gleam/string
import gleam/base
import gleam/option.{None, Some}
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/erlang/process.{Subject}
import gleam/crypto.{strong_random_bytes}
import nakai/html
import nakai/html/attrs
import gliew
// This is only here for this example.
// It implements an actor that keeps an
// incrementing counter and can be
// subscribed to.
import gliew/integration/counter.{
  CounterMessage, reset, start_counter, subscribe,
}

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
    gliew.new(
      8080,
      fn(req) {
        case req.method, request.path_segments(req) {
          Get, ["mounts"] ->
            mounts_page(count_actor)
            |> gliew.view(200)
          Post, ["counter", "reset"] -> reset_counter(count_actor)
          _, _ ->
            home_page()
            |> gliew.view(200)
        }
      },
    )
    |> gliew.serve

  process.sleep_forever()
}

// You can just return a simple nakai node tree for
// a static page.
fn home_page() {
  html.div_text([], "Hello gleam!")
}

fn reset_counter(count_actor: Subject(CounterMessage)) {
  reset(count_actor)

  gliew.response(204)
}

fn mounts_page(count_actor: Subject(CounterMessage)) {
  // Return the HTML for the page.
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
      // Random text
      html.div_text([attrs.style("font-size: x-large")], "Random text for you"),
      random_text(),
      // Counter
      html.div_text([attrs.style("font-size: x-large")], "Counter is at"),
      counter(count_actor),
      html.div(
        [],
        [
          html.button_text([], "Reset")
          |> gliew.on_click(do: Post, to: "/counter/reset"),
        ],
      ),
      // Explanation text
      html.div(
        [
          attrs.style(
            [
              "background-color: #d0ebf4", "padding: 1em", "color: #222",
              "border-radius: 1em", "width: 21em", "margin-top: 0.5em",
            ]
            |> string.join(";"),
          ),
        ],
        [
          html.div_text(
            [attrs.style("font-size: x-large; margin-bottom: 0.5em;")],
            "This page is live rendered.",
          ),
          html.div_text(
            [attrs.style("font-size: large")],
            "Once the browser has made a connection to the server a new random text is generated every 5 seconds and the counter above should auto-increment.",
          ),
        ],
      ),
    ],
  )
}

//                           //
// Global counter live mount //
//                           //

// A live mount that shows a live updating counter.
fn counter(count_actor: Subject(CounterMessage)) {
  // Makes the function a live mount.
  // The second parameter passed to `gliew.live_mount` will
  // be passed to the mount function (first parameter)
  // when the mount is mounted (i.e. the client connects
  // back to the server to get live updates).
  //
  // The returned value is of type `Option(a)` where
  // `a` is the type in the Subject returned by mount.
  use assign <- gliew.live_mount(counter_mount, with: count_actor)

  let text = case assign {
    // View has been mounted and we want to use the
    // "live" value that was setup in the mount function.
    Some(counter) ->
      counter
      |> int.to_string
    // View is being rendered on the server before
    // the client has made a connection back to the server.
    // Here we contact the count_actor to get the current
    // value.
    None -> "Loading.."
  }

  // Return the HTML of the view.
  html.div_text([attrs.style("font-size: xx-large"), gliew.morph()], text)
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

  // Return the subject.
  subject
}

//                        //
// Random text live mount //
//                        //

// A live mount that renders random text on an interval.
fn random_text() {
  use assign <- gliew.live_mount(text_mount, with: Nil)

  html.div_text(
    [attrs.style("font-size: xx-large"), gliew.morph()],
    assign
    |> option.unwrap(random_string()),
  )
}

// The mount function used for the random_text mount.
// It will generate random text on an interval and
// send it on the returned subject.
fn text_mount(_) {
  let subject = process.new_subject()

  let _ = process.start(fn() { loop(subject) }, True)

  subject
}

// Random text loop.
fn loop(subject: Subject(String)) {
  process.send(subject, random_string())
  process.sleep(5000)
  loop(subject)
}

// Helper function to generate random string.
fn random_string() {
  strong_random_bytes(10)
  |> base.encode64(False)
}

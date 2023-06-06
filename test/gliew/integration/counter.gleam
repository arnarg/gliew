import gleam/list
import gleam/function
import gleam/otp/actor
import gleam/erlang/process.{Subject}

type CounterState {
  CounterState(
    self: Subject(CounterMessage),
    counter: Int,
    subscribers: List(Subject(Int)),
  )
}

pub opaque type CounterMessage {
  Increment
  Reset
  Subscribe(subject: Subject(Int))
  GetCurrent(from: Subject(Int))
}

pub fn start_counter() {
  actor.start_spec(actor.Spec(
    init: fn() {
      let subj = process.new_subject()
      let selector =
        process.new_selector()
        |> process.selecting(subj, function.identity)

      // Send the initial increment message
      let _ = process.send_after(subj, 1000, Increment)

      // Actor ready
      actor.Ready(CounterState(subj, 0, []), selector)
    },
    init_timeout: 1000,
    loop: counter_loop,
  ))
}

fn counter_loop(msg: CounterMessage, state: CounterState) {
  case msg {
    // Increment the counter.
    // Should happen every second.
    Increment -> {
      // Increment the counter by 1.
      let new_counter = state.counter + 1

      // Send new counter to all subscribers while also
      // filtering for dead processes.
      let new_subscribers = send_to_all(new_counter, state.subscribers)

      // Send an increment to ourselves in a second.
      let _ = process.send_after(state.self, 1000, Increment)

      // Continue actor.
      actor.Continue(
        CounterState(
          ..state,
          counter: new_counter,
          subscribers: new_subscribers,
        ),
      )
    }
    // Reset the counter.
    Reset -> {
      // Send 0 to all subscribers while also filtering for
      // dead processes.
      let new_subscribers = send_to_all(0, state.subscribers)

      // Send an increment to ourselves in a second.
      process.send_after(state.self, 1000, Increment)

      // Continue actor.
      actor.Continue(
        CounterState(..state, counter: 0, subscribers: new_subscribers),
      )
    }
    // Subscribe to the counter.
    Subscribe(subject) -> {
      // Send current value
      process.send(subject, state.counter)

      // Continue actor with new subject subscribed
      actor.Continue(
        CounterState(
          ..state,
          subscribers: state.subscribers
          |> list.prepend(subject),
        ),
      )
    }
    // Return current state.
    GetCurrent(from) -> {
      process.send(from, state.counter)

      actor.Continue(state)
    }
  }
}

fn send_to_all(counter: Int, subscribers: List(Subject(Int))) {
  case subscribers {
    [] -> subscribers
    [next, ..rest] ->
      case
        process.is_alive(
          next
          |> process.subject_owner,
        )
      {
        True -> {
          process.send(next, counter)

          send_to_all(counter, rest)
          |> list.prepend(next)
        }
        False -> send_to_all(counter, rest)
      }
  }
}

pub fn get_current(count_actor: Subject(CounterMessage)) {
  process.call(count_actor, GetCurrent, 1000)
}

pub fn subscribe(count_actor: Subject(CounterMessage), subscriber: Subject(Int)) {
  process.send(count_actor, Subscribe(subscriber))
}

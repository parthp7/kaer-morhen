# Raise Sure's undelivered-response timeout so slow LOCAL models can finish.
#
# Bind-mounted into the container at /rails/config/initializers/ rather than
# baked into the image: `ghcr.io/we-promise/sure:stable` is a moving tag, so a
# patched image would be overwritten by the next `docker compose pull`. A
# mounted initializer is additive and survives upgrades.
#
# WHY THIS IS NEEDED
# Sure gives an assistant reply ~90 s and then throws it away. Two timers:
#   1. a browser watchdog (chat_controller.js, responseTimeout 90_000 ms) that
#      POSTs .../report_timeout once a "Thinking…" bubble is older than 90 s;
#   2. this server-side constant, which the controller re-checks under a row
#      lock before acting — it destroys the pending AssistantMessage only if it
#      is genuinely older than the timeout.
# Neither is exposed as an ENV var or a Setting (checked in the running image,
# 2026-08-01). Raising THIS one is sufficient: the browser still reports at
# 90 s, but the server declines to act, the message survives, and the reply
# renders over Turbo Stream whenever the Sidekiq job finishes.
#
# Cost: a genuinely stuck reply now shows "Thinking…" for the full window
# instead of surfacing an error at 90 s. Keep it comfortably above the slowest
# real answer, and below OPENAI_REQUEST_TIMEOUT (300 s) so a hung HTTP call is
# still the thing that fails first.
#
# Guarded so an upstream rename degrades to stock behaviour instead of a
# boot-time NameError that would take the whole app down.
Rails.application.config.to_prepare do
  timeout = ENV.fetch("LLM_UNDELIVERED_RESPONSE_TIMEOUT", "240").to_i

  if timeout.positive? && defined?(Chat) && Chat.const_defined?(:UNDELIVERED_RESPONSE_TIMEOUT)
    Chat.send(:remove_const, :UNDELIVERED_RESPONSE_TIMEOUT)
    Chat.const_set(:UNDELIVERED_RESPONSE_TIMEOUT, timeout.seconds)
    Rails.logger.info("[kaer-morhen] Chat::UNDELIVERED_RESPONSE_TIMEOUT set to #{timeout}s")
  end
end

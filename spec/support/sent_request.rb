# frozen_string_literal: true

# For a spec that defines `klass` (a squished class) and `answer` (a valid reply): calls klass with the arguments
# against a fake adapter and returns the request it sent.
module SentRequest
  def sent_request(**arguments)
    fake = fake_squishling { |llm| llm.step(:any).reply(answer) }
    klass.call(**arguments)
    fake.requests.first
  end
end

# Images

A squished method can read images: pass a `Squishling::Image` as an argument, and the model gets it with the call's
input. Use it for receipts, screenshots, scanned forms, or anything you'd otherwise run through OCR first.

```ruby
class ReceiptReader
  include Squishling

  squishling escalation: [{ model: "gpt-5-mini", attempts: 2 }, "gpt-5"]
  purpose "Read the totals off this receipt."
  output_schema do
    optional(:total_cents, description: "The amount charged, tip included, in cents") { integer }
    optional(:date, description: "The transaction date, YYYY-MM-DD") { string }
  end
end

ReceiptReader.call(image: Squishling::Image.from_path("receipt.jpg"), note: "team lunch")
```

## Making an image

| | |
|---|---|
| `Squishling::Image.from_path(path)` | Reads the file. The media type comes from the bytes (or the extension). |
| `Squishling::Image.new(data: bytes)` | Bytes you already have (an upload, an ActiveStorage download). Pass `media_type:` if it can't be read from them. |
| `Squishling::Image.from_url(url)` | An http(s) URL the provider fetches itself. Nothing is downloaded here, so the URL has to be reachable from the provider (a signed URL works). |

PNG, JPEG, GIF, and WebP are supported. `detail: :low` or `:high` asks the provider to spend fewer or more tokens on
the image; providers without the setting ignore it. For a PDF, render its pages to images (one `Image` per page) and
pass them as an Array; text you can extract from the PDF can go alongside as a plain argument.

## What the model sees

Each image is replaced in the JSON input by `{"attached_image": N}`, and the images go with the call's first message,
after the text, in that order. The system prompt gets one line explaining the placeholders. So for
`call(front: a, back: b)` the input is `{"arguments":{"front":{"attached_image":1},"back":{"attached_image":2}}}`, with
`a` and `b` attached. The same `Image` passed twice is attached once. Images can sit inside Hashes and Arrays, and in
`squish_context` values.

The Ruby path gets the `Image` objects as they were passed.

Every chat starts with the images: a retry continues the same chat (the model already has them), an escalation to a new
step starts a fresh chat that carries them again, and a sample harness sends them to every sample. A `:chat` judge is
sent them with the input it judges. A `type: :judgment` judge can't see images, so a call with images and such a judge
raises `ConfigurationError` before any request.

## Adapters

The RubyLLM adapter sends images as RubyLLM attachments, and the OpenAI-compatible adapter as `image_url` content parts
(a `data:` URI, or the image's own URL); the model has to accept images. RubyLLM downloads a URL image itself when the
URL's path has no image extension (to tell its type) or when the provider can't fetch URLs, so with RubyLLM a URL has to
be reachable from your process too. A [custom adapter](adapters.md#images) opts
in with `images?`. A call with images through an adapter that doesn't take them raises `ConfigurationError` before any
request is made.

## Untrusted URLs and paths

Build an `Image` only from sources you trust, or check them first. Squishling doesn't filter hosts or paths:

- **`Image.from_url`**: with the OpenAI-compatible adapter the provider fetches the URL. With the RubyLLM adapter your
  own process may download it (see [Adapters](#adapters)), following redirects, from any host it can reach, including
  `localhost`, private addresses, and cloud metadata endpoints. What it fetches is then sent to the provider. If a user
  can choose the URL, allow-list its host (and scheme) before building the `Image`, or download it yourself and pass
  the bytes with `Image.new(data:)`.
- **`Image.from_path`**: reads whatever file the path names, so never pass it a path a user chose without confining it
  to a directory you control.

## Privacy and logs

An image is input, like any argument: it goes to the provider (and to a judge's provider). It never goes anywhere else.
`Image#inspect`, `#to_s`, `#as_json`, `#to_json`, and YAML describe the image (media type and size, or the URL without its
query or credentials), so an image that ends up in a log line, an error, or a serialized object carries no content. `Marshal.dump` of an
image raises `TypeError`: keep the bytes (or a URL) in your own storage and build the `Image` where the call is made.
`squawk` reports carry the JSON input with its placeholders, never the bytes, and observers never see input.

Images are billed as input tokens by the provider, and the [token budget](failures.md#capping-a-calls-cost-token-budgets)
counts them through the usage the provider reports. [Prompt caching](configuration.md#prompt-caching) still caches the
system prompt; the images are part of the message, not the cached prefix.

## Testing

`Squishling::Testing::Request#images` lists the images a request was sent with, and `arguments` shows their
placeholders. `squishling_preview` returns them as `images:`.

```ruby
fake = fake_squishling { |llm| llm.step(:any).reply({ "total_cents" => 1234 }) }
ReceiptReader.call(image:)
fake.requests.first.images      # => [image]
fake.requests.first.arguments   # => { "image" => { "attached_image" => 1 } }
```

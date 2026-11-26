# Images

A squished method can read images: pass a file as an argument (an ActiveStorage blob or attachment, an upload, a
`File`, a `Pathname`, ...) and the model gets it with the call's input. You don't wrap it or declare it. Use it for
receipts, screenshots, scanned forms, or anything you'd otherwise run through OCR first. This page is about images;
[Inputs](inputs.md) covers every kind of file (PDFs, HL7, FHIR, a fax), what is read from where, the limits, and
`squish_sanitize`, which filters or rewrites whatever is sent.

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

ReceiptReader.call(image: Pathname("receipt.jpg"), note: "team lunch")
ReceiptReader.call(image: receipt.file, note: "team lunch")   # an ActiveStorage attachment
```

Which files are recognized, and how, is on [Inputs](inputs.md#passing-files-directly).

## Making an image

| | |
|---|---|
| `Squishling::Image.from_path(path)` | Reads the file. The media type comes from the bytes (or the extension). |
| `Squishling::Image.new(data: bytes)` | Bytes you already have (an upload, an ActiveStorage download). Pass `media_type:` if it can't be read from them. |
| `Squishling::Image.from_url(url, media_type: nil)` | An http(s) URL the provider fetches itself. Nothing is downloaded here, so the URL has to be reachable from the provider (a signed URL works). The media type is the one you give, or the one the path's extension says (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`); a URL with neither (`/files/123?sig=...`) needs `media_type:` with the RubyLLM adapter. |

PNG, JPEG, GIF, and WebP are supported. `detail: :low` or `:high` asks the provider to spend fewer or more tokens on
the image; providers without the setting ignore it. A PDF is not an image: pass it as it is (a file, a blob, or a
`Squishling::Document`) and the model reads it natively; see [Inputs](inputs.md).

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

An adapter says which types it takes (`Adapter::Base#media_types`), per model: a call with an image of another type, or
to a model RubyLLM knows can't read images, raises `ConfigurationError` before any request. For a model an adapter
can't judge, the provider's refusal (a 400) comes back as `RequestRejectedError`, never retried or sent to a fallback.
An escalation where a later step can't take the images fails when the call starts, not after the first step.

The RubyLLM adapter sends images as RubyLLM attachments, and the OpenAI-compatible adapter as `image_url` content parts
(a `data:` URI, or the image's own URL); the model has to accept images. The RubyLLM adapter hands RubyLLM the image's
media type along with its URL, so RubyLLM never downloads a URL to find the type out; a URL image with no known type
(no image extension and no `media_type:`) raises `ConfigurationError` before any request, naming the fix. RubyLLM can
still download a URL image itself for a provider that can't fetch URLs, so with RubyLLM a URL may have to be reachable
from your process too. A [custom adapter](adapters.md#images-and-documents) opts
in with `images?`. A call with images through an adapter that doesn't take them raises `ConfigurationError` before any
request is made.

## Untrusted URLs and paths

Build an `Image` only from sources you trust, or check them first. Squishling doesn't filter hosts or paths:

- **`Image.from_url` with the RubyLLM adapter is a known risk, smaller than it was.** RubyLLM, not Squishling, may still
  download the URL from your own process for a provider that can't fetch URLs (see [Adapters](#adapters); it no longer
  downloads one just to learn its type), following redirects, from any host it can reach, including `localhost`,
  private addresses, and cloud metadata endpoints, and what it fetches is then sent to the provider. If a user can
  choose the URL, allow-list its host and scheme before building the `Image`, or download it yourself and pass the
  bytes with `Image.new(data:)`. See [the adapter note](adapters.md#known-risk-the-rubyllm-adapter-downloads-some-image-urls-itself).
  The OpenAI-compatible adapter never downloads: the provider fetches the URL.
- **`Image.from_path`, and a `Pathname` or `File` argument,** read whatever file the path names, so never pass one a
  path a user chose without confining it to a directory you control (a sanitizer can check `path` and the file).

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

`Squishling::Testing::Request#images` (and `#documents`, for PDFs) lists the files a request was sent with, and
`arguments` shows their placeholders. `squishling_preview` returns them as `images:` and `documents:`.

```ruby
fake = fake_squishling { |llm| llm.step(:any).reply({ "total_cents" => 1234 }) }
ReceiptReader.call(image:)
fake.requests.first.images      # => [image]
fake.requests.first.arguments   # => { "image" => { "attached_image" => 1 } }
```

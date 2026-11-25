# Inputs

Everything a squished method is called with goes to the model as JSON: Strings, numbers, Hashes, Arrays. Files go
alongside it. You don't declare any of it or wrap it in a Squishling type: pass what you have, and apply a policy to
all of it with [`squish_sanitize`](#sanitizing-inputs).

| You pass | The model gets |
|---|---|
| A String (an HL7 v2 message, a note) or a Hash/Array (a FHIR resource, parsed) | It as text, in the JSON `arguments` |
| An image (PNG, JPEG, GIF, WebP) | The image, as `{"attached_image": N}` in the input (see [Images](images.md)) |
| A PDF | The document, as `{"attached_document": N}` |
| A text file (`.hl7`, `.json`, `.csv`, `.xml`, `.txt`) | Its text, as if you had passed the String |
| A TIFF (a fax), a HEIC (an iPhone photo), anything else | Nothing, until a sanitizer converts it: the call is refused, saying so |

```ruby
class ChartReader
  include Squishling

  squishling model: "gpt-5"
  purpose "Summarize this patient's chart."
  output_schema { string :summary }
end

ChartReader.call(adt: File.read("adt.hl7"), bundle: JSON.parse(bundle_json), scan: referral.pdf, note: note_photo)
```

Pass FHIR as a parsed Hash, not a JSON String: a String is sent as an escaped string inside the JSON.

## Passing files directly

Squishling recognizes these by what they respond to, so no ActiveStorage or Rack dependency is needed:

| Passed | Read as |
|---|---|
| ActiveStorage blob or attachment (`download`, `content_type`, `byte_size`) | its bytes |
| `has_one_attached` (`attached?`, `attachment`) | its file, or `nil` when nothing is attached |
| `has_many_attached` (`attachments`, `attached?`) | one file per attachment |
| An upload (`tempfile`, `content_type`, `original_filename`) | its tempfile |
| `File`, `Tempfile`, `StringIO`, or any IO | everything in it (the position you left it at is restored) |
| `Pathname` | the file (a `Pathname` that used to go out as text now reads the file, so pass a String for a path you mean as text) |
| A binary String that starts with a known file signature (PDF, PNG, JPEG, GIF, WebP, TIFF, HEIC) | that file: what `download`, `File.binread`, or a webhook body returns |
| An `http(s)` `URI` whose path ends in an image extension | an image URL the provider fetches |

What a file is comes from its bytes, then its declared type, then its name's extension. A text String is never read
as a file: a string that names a path would let input choose which file leaves the process, and a text String that
happens to start with `%PDF-` is still text. Only the LLM path reads files: the Ruby path gets exactly what was passed.

A file that is empty, can't be read, or is over a limit raises `InputRejectedError` before any request, naming where it
was (`arguments.scan`) but never the file. A Hash key that isn't a plain identifier (a name, an MRN) appears as `[key]` in
that path. A binary String that is neither a known file nor UTF-8 text is refused too.

### Arrays of files

Each file in an Array (or Hash, or `has_many_attached`) is its own placeholder, in order: `pages: [a, b, c]` is sent as
`{"pages":[{"attached_image":1},{"attached_image":2},{"attached_image":3}]}`, so the model can tell which is which.
Images and documents are numbered apart. The same file passed twice is attached once, and so are two files with
identical bytes. The call is all or nothing: if any file is refused, the whole call is. A file that can't be read stops the call at
that file, named by its path; the sanitizers and the serializer list every problem at once. Files are counted
against `max_files` as they are read, before duplicates are merged. Each sanitizer is held to the limit again for the files it returns, and the
call's final files are counted once more. Filter your own Array first to send only some.

### Limits

`config.max_files` (20) and `config.max_file_bytes` (20 MB, per file) bound a call, explicit `Squishling::Image`s and
`Squishling::Document`s included; set either to `nil` to lift it. A file's size is checked before it is read when it is
known (a blob's `byte_size`, a `File`'s size), and a stream of unknown size is read no further than one byte past the limit, so an
oversized file is refused without being loaded whole. Text isn't capped by these: bound it in a sanitizer, or with a
[token budget](failures.md#capping-a-calls-cost-token-budgets).

## Sanitizing inputs

`squish_sanitize` filters or rewrites everything a call would send, before any request: de-identify health data, convert
a fax, scan an upload, refuse what shouldn't leave. It is offered every node of the input, parents before their
children, and what it returns is what the model gets.

```ruby
class ChartReader
  squish_sanitize do |value:, path:, reject:, **|
    case value
    when String then value.gsub(/\b\d{3}-\d{2}-\d{4}\b/, "[SSN]")
    when Hash then path.end_with?(".resource") ? value.except("ssn", "mrn") : value
    when Squishling::Document
      reject.call("fax is over 10 MB") if value.bytesize > 10_000_000
      value.media_type == "image/tiff" ? Tiff.to_pdf(value) : value   # your own converter
    else value
    end
  end
end
```

| Keyword | |
|---|---|
| `value` | The node: a Hash, Array, String, number, `true`/`false`/`nil`, or a `Squishling::Image` or `Squishling::Document` (`media_type`, `bytesize`, `data`). Any other object is offered as the plain data it serializes to (a Struct, a Set, a model's `to_json`, a Date as a String), so you see what would be sent. |
| `path` | Where it is: `"arguments.bundle.entry[0].resource"`, or `"context.mrn"` for a `squish_context` value or a `squish!` `context:` |
| `reject` | Call it with a message (or an Array of them) to refuse the call. It records the problem and carries on, so one error lists every one |

Declare only the keywords you use. Evaluated against the instance, so it can call your own methods.

- **The return value replaces the node, always.** Return `value` to keep it. Returning `nil` sends `nil`: nothing is
  "unchanged" by accident. What you return is read like any input (even the node itself, changed in place), so a converter can return a
  `File`, a `StringIO`, or a `Pathname`, and a Hash you return has its children offered next. Strings are copies, so
  changing one in place never changes the caller's. Returning a Hash without a key drops the field.
- **Converting a file.** No provider takes TIFF or HEIC, and Squishling ships no converters. Return a PNG, JPEG, or PDF
  from yours. A file still of a type no adapter sends after the sanitizers have run is refused, naming where it was.
- **Rejecting.** `reject.call("message")` raises `Squishling::InputRejectedError` after the pass, with every problem in
  `rejections` (`path` and `message`). No request is made, and `squish_fallback` does not absorb it: the input is what is
  wrong, so you decide what to do. Write messages without the value in them.
- **Failing closed.** A sanitizer that raises stops the call with its own exception, and nothing is sent.
- **Levels compose.** `config.sanitizer = hook` (or a list), `squish_sanitize` on a class (a subclass adds to its
  parent's), and `squish :method, sanitize: hook` all run, in that order, each over what the one before returned. None
  can switch another off, `false` is refused, and `squish!` has no way around them.

### What it covers

It covers the arguments, `squish_context` values, and a `squish!` call's `context:`: everything that leaves the
process as input. The squawk report's `input`, a judge, and escalation all build from what it returned, as does
`Squishling::Testing.preview`. It does **not** cover:

- The purpose and `append_to_purpose` (your own text and source).
- The Ruby path, `squish_when`, and `squish_fallback`, which get the input as it was passed. An
  [apprentice](apprentice.md) therefore compares the Ruby result on the raw input with the model's on the sanitized one.
- Hash keys, which are never offered: don't put values in them. (They are masked in an error's path, not in what
  is sent.)
- What the model returns: a rejected output is forwarded to the next escalation step as the model wrote it.

A sanitizer is a place to enforce a policy, not a compliance program: whether a provider may receive health data at all
is for your agreements and counsel.


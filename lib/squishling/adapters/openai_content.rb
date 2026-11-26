# frozen_string_literal: true

module Squishling
  module Adapters
    # A message's content as the Chat Completions API takes it: a String as is, or content parts (see
    # Adapter::Request) as text, image_url (an image as a data: URI or its own URL) and file (a PDF as a data: URI)
    # parts.
    module OpenAIContent
      module_function

      def of(value)
        return value unless value.is_a?(Array)

        value.map { |part| part_of(part) }
      end

      def part_of(part)
        case part[:type]
        when :image then image(part[:image])
        when :file then file(part[:file])
        else { "type" => "text", "text" => part[:text] }
        end
      end

      def file(document)
        { "type" => "file", "file" => { "filename" => document.filename, "file_data" => document.data_uri } }
      end

      def image(image)
        url = { "url" => image.url || image.data_uri }
        url["detail"] = image.detail.to_s if image.detail
        { "type" => "image_url", "image_url" => url }
      end
    end
  end
end

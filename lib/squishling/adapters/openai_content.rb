# frozen_string_literal: true

module Squishling
  module Adapters
    # A message's content as the Chat Completions API takes it: a String as is, or content parts (see
    # Adapter::Request) as text and image_url parts, an image as a data: URI or its own URL.
    module OpenAIContent
      module_function

      def of(value)
        return value unless value.is_a?(Array)

        value.map { |part| part[:type] == :image ? image(part[:image]) : { "type" => "text", "text" => part[:text] } }
      end

      def image(image)
        url = { "url" => image.url || image.data_uri }
        url["detail"] = image.detail.to_s if image.detail
        { "type" => "image_url", "image_url" => url }
      end
    end
  end
end

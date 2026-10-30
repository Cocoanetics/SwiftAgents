import ArgumentParser
import Foundation
import Providers

@main
struct ImageGen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "imagegen",
        abstract: "Generate and edit images with the OpenAI Images API.",
        discussion: """
        Calls the public Images API, which honours every setting (model, size, quality, \
        background, format). The ChatGPT-subscription Codex backend does not.

        Models (--model):
        \(ImageModel.known.map { "  \($0.model)  \($0.guidance)" }.joined(separator: "\n"))
        Any other name is passed through unchanged.

        Size: auto or WIDTHxHEIGHT. Recommended: 1024x1024, 1536x1024, 1024x1536. Custom \
        sizes need both sides to be multiples of 16, the longest side at most 3840, an aspect \
        ratio between 1:3 and 3:1, and 655,360 to 8,294,400 total pixels. Above 2560x1440 is \
        experimental. Presets: \(SizePreset.helpList).

        Quality: low, medium, high, auto; xhigh and max only on the 2.5 models. Transparent \
        backgrounds need a 2.5 model and --output-format png or webp.

        The API key is read from OPENAI_API_KEY, otherwise from --api-key-file. --dry-run \
        needs no key.
        """,
        subcommands: [Generate.self, Edit.self, GenerateBatch.self]
    )
}

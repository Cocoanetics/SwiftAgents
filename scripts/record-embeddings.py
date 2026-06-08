#!/usr/bin/env python3
"""Regenerate Tests/ProvidersTests/Resources/recorded_openai_embeddings.json.

Records real OpenAI `text-embedding-3-small` vectors for a tiny fixed corpus so
the semantic-search tests can replay them deterministically (no API key needed
at test time, every platform). Run from the repo root with OPENAI_API_KEY set:

    OPENAI_API_KEY=sk-... python3 scripts/record-embeddings.py

Keep the strings below in sync with the recorded* tests in
LocalVectorStoreTests / SQLiteVectorStoreTests — they are the exact chunk texts
the stores embed.
"""
import json, os, urllib.request

TEXTS = [
    "When did Leopold Pasching die?",
    "Leopold Pasching, an Austrian engineer, died on 13 February 1962 in Vienna.",
    "The Eiffel Tower is an iron lattice tower on the Champ de Mars in Paris, France.",
    "Honeybees communicate the location of nectar to the hive through a waggle dance.",
    "The central bank raised its benchmark interest rate by half a percentage point.",
]
OUT = "Tests/ProvidersTests/Resources/recorded_openai_embeddings.json"


def main() -> None:
    key = os.environ["OPENAI_API_KEY"]
    request = urllib.request.Request(
        "https://api.openai.com/v1/embeddings",
        data=json.dumps({"model": "text-embedding-3-small", "input": TEXTS}).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    response = json.load(urllib.request.urlopen(request))
    embeddings = [item["embedding"] for item in response["data"]]
    with open(OUT, "w") as handle:
        json.dump({t: e for t, e in zip(TEXTS, embeddings)}, handle)
    print(f"wrote {len(TEXTS)} embeddings ({len(embeddings[0])}-d) to {OUT}")


if __name__ == "__main__":
    main()

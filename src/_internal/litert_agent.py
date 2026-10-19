import asyncio
import os
import sys

from google.antigravity import Agent, LiteRTAgentConfig

MODEL_PATH = os.environ.get("ANTIGRAVITY_LITERT_MODEL_PATH", "").strip()
BACKEND = os.environ.get("ANTIGRAVITY_LITERT_BACKEND", "gpu").strip() or "gpu"
CACHE_DIR = os.environ.get("ANTIGRAVITY_LITERT_CACHE_DIR", "").strip()


async def run(prompt: str):
    if not MODEL_PATH:
        raise RuntimeError("LiteRT model path is missing.")
    config = LiteRTAgentConfig(
        model_path=MODEL_PATH,
        backend=BACKEND,
        cache_dir=CACHE_DIR or None,
    )
    async with Agent(config=config) as agent:
        response = await agent.chat(prompt)
        chunks = []
        async for token in response:
            chunks.append(token)
        return "".join(chunks)


async def main():
    prompt = (
        os.environ.get("ANTIGRAVITY_LOCAL_PROMPT", "").strip()
        or " ".join(sys.argv[1:]).strip()
        or "Reply with only: OK"
    )
    print(await run(prompt))


if __name__ == "__main__":
    asyncio.run(main())

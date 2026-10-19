import asyncio
import os
import sys
from google.antigravity import Agent, LocalOpenAIAgentConfig

MODEL = "__MODEL__"
BASE_URL = "__BASE_URL__"

async def run(prompt: str):
    config = LocalOpenAIAgentConfig(model=MODEL, base_url=BASE_URL).lightweight()
    async with Agent(config) as agent:
        response = await agent.chat(prompt)
        chunks = []
        async for token in response:
            chunks.append(token)
        return "".join(chunks)

async def main():
    prompt = os.environ.get("ANTIGRAVITY_LOCAL_PROMPT", "").strip() or " ".join(sys.argv[1:]).strip() or "Reply with only: OK"
    print(await run(prompt))

if __name__ == "__main__":
    asyncio.run(main())

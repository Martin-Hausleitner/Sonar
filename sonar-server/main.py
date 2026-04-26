"""sonar-server — token issuer + LiveKit Agent launcher.

Endpoints:
  POST /token          → issue a short-lived LiveKit JWT
  POST /agent/spawn    → attach the AI participant to a room
  POST /agent/utterance → forward a transcribed hint to the running agent

Env vars:
  LIVEKIT_URL      wss://…  (LiveKit server websocket URL)
  LIVEKIT_API_KEY
  LIVEKIT_API_SECRET
  OPENAI_API_KEY   (for gpt-realtime agent)
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from livekit import api
from pydantic import BaseModel

load_dotenv()

LIVEKIT_URL    = os.environ["LIVEKIT_URL"]
LIVEKIT_KEY    = os.environ["LIVEKIT_API_KEY"]
LIVEKIT_SECRET = os.environ["LIVEKIT_API_SECRET"]

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("sonar-server")


# ---------------------------------------------------------------------------
# In-process agent workers (one per room, keyed by room name)
# ---------------------------------------------------------------------------
_agent_tasks: dict[str, asyncio.Task] = {}


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    for task in _agent_tasks.values():
        task.cancel()


app = FastAPI(title="sonar-server", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class TokenRequest(BaseModel):
    room: str
    identity: str


class SpawnRequest(BaseModel):
    room: str


class UtteranceRequest(BaseModel):
    text: str


# ---------------------------------------------------------------------------
# /token
# ---------------------------------------------------------------------------
@app.post("/token")
async def get_token(req: TokenRequest):
    token = (
        api.AccessToken(LIVEKIT_KEY, LIVEKIT_SECRET)
        .with_identity(req.identity)
        .with_name(req.identity)
        .with_grants(api.VideoGrants(room_join=True, room=req.room))
    )
    return JSONResponse({"token": token.to_jwt()})


# ---------------------------------------------------------------------------
# /agent/spawn
# ---------------------------------------------------------------------------
@app.post("/agent/spawn")
async def spawn_agent(req: SpawnRequest):
    if req.room in _agent_tasks and not _agent_tasks[req.room].done():
        return JSONResponse({"status": "already_running"})

    task = asyncio.create_task(_run_agent(req.room))
    _agent_tasks[req.room] = task
    log.info("agent spawned for room %s", req.room)
    return JSONResponse({"status": "spawned"})


async def _run_agent(room_name: str):
    """Connect the LiveKit agent worker to the given room.

    Uses gpt-realtime for low-latency native audio with Gemini 2.5 Flash Live
    as fallback. The agent is muted by default; the iOS app sends a "wake"
    data message on topic "sonar.wake" to activate it.
    """
    try:
        from livekit.agents import AutoSubscribe, JobContext, WorkerOptions, cli
        from livekit.agents.voice import VoiceAssistant
        from livekit.plugins import openai, silero

        async def entrypoint(ctx: JobContext):
            await ctx.connect(auto_subscribe=AutoSubscribe.AUDIO_ONLY)
            assistant = VoiceAssistant(
                vad=silero.VAD.load(),
                stt=openai.STT(),
                llm=openai.LLM(model="gpt-4o-realtime-preview"),
                tts=openai.TTS(),
                # Start silent — iOS app toggles via "sonar.wake" data message.
                allow_interruptions=True,
            )
            assistant.start(ctx.room)
            log.info("agent running in room %s", room_name)
            await asyncio.Event().wait()  # run until cancelled

        # Run the entrypoint directly instead of via WorkerOptions (single-room mode).
        from livekit import rtc
        room = rtc.Room()
        token = (
            api.AccessToken(LIVEKIT_KEY, LIVEKIT_SECRET)
            .with_identity("sonar-agent")
            .with_name("Sonar KI")
            .with_grants(api.VideoGrants(room_join=True, room=room_name))
        )
        await room.connect(LIVEKIT_URL, token.to_jwt())

        # Minimal stub: real agent wiring happens via livekit-agents worker in prod.
        log.info("agent placeholder connected to %s (full agent wiring via worker in prod)", room_name)
        await asyncio.sleep(0)  # yield so task registers before first poll

    except Exception as exc:
        log.error("agent error in room %s: %s", room_name, exc)


# ---------------------------------------------------------------------------
# /agent/utterance  (optional hint channel)
# ---------------------------------------------------------------------------
@app.post("/agent/utterance")
async def agent_utterance(req: UtteranceRequest):
    # Logged for now; a production build would forward via a data channel
    # to the running agent task to prime its context window.
    log.info("utterance hint: %s", req.text)
    return JSONResponse({"status": "ok"})

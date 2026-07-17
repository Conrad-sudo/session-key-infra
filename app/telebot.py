import os
import asyncio
from datetime import date
from telegram import Update
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    filters,
    ContextTypes,
)
from smart_wallet_agent import chat, init_agent,open_checkpointer,close_checkpointer
from tools import get_all_sessions

telegram_token = os.getenv("TELEGRAM_TOKEN")


async def session_expiry_alert(context: ContextTypes.DEFAULT_TYPE):
    """
    Job callback that checks all sessions for a user and sends a Telegram
    message for any session expiring within the next 24 hours.

    Scheduled via JobQueue — not triggered by a user message.
    Uses context.job.chat_id to identify the user.
    """
    chat_id = context.job.chat_id
    sessions = get_all_sessions.func(chat_id)
    if not sessions:
        return

    today = date.today()
    for s in sessions:
        end_date = date.fromisoformat(s["end_time"])
        days_remaining = (end_date - today).days
        if days_remaining <= 1:
            await context.bot.send_message(
                chat_id=chat_id,
                text=(
                    f"⚠️ Your {s['target'].upper()} session key is expiring "
                    f"{'today' if days_remaining <= 0 else 'tomorrow'}. "
                    f"Please renew it to continue making transactions."
                ),
            )


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.message.chat_id
    # Schedule the daily expiry check for this user, replacing any existing job
    current_jobs = context.job_queue.get_jobs_by_name(str(chat_id))
    for job in current_jobs:
        job.schedule_removal()
    context.job_queue.run_repeating(
        session_expiry_alert,
        interval=86400,  # every 24 hours
        first=10,  # first run 10 seconds after /start
        chat_id=chat_id,
        name=str(chat_id),
    )
    await update.message.reply_text(
        "Welcome to your smart wallet assistant.\n" "Simply say Hi to start chatting."
    )


async def help_cmd(update: Update, _context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text("Help menu")


async def start_chat(update: Update, _context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.message.chat_id

    query = update.message.text

    # chat() is synchronous/blocking — run it in a thread to avoid blocking the event loop
    response = await asyncio.to_thread(chat, chat_id, query)
    await update.message.reply_text(response)


async def post_init(application: Application) -> None:
    """
    Called once after the Application is initialised but before polling starts.

    Opens the checkpointer and initialises the agent.
    """
    await open_checkpointer()
    init_agent()

async def post_shutdown(application: Application) -> None:
    await close_checkpointer()


def main():
    app = Application.builder().token(telegram_token).post_init(post_init).post_shutdown(post_shutdown).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_cmd))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, start_chat))
    app.run_polling()


if __name__ == "__main__":
    main()

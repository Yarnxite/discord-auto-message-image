import discord
from discord.ext import tasks
import logging
import asyncio
import keyboard
import os
from datetime import datetime

logging.basicConfig(level=logging.INFO)

# Replace with your Discord token
TOKEN = 'TOKEN'
# Replace with your Discord channel ID
CHANNEL_ID = 1234567890

IMAGE_PATH = r"PATH"

client = discord.Client()

# Counter for tracking the number of messages sent
message_count = 0

async def on_ready():
    print(f'Logged in as {client.user}')
    send_message.start()  # Start the send_message task
    await check_for_exit_key()

@tasks.loop(seconds=130)  # Loop interval
async def send_message():
    global message_count
    try:
        channel = client.get_channel(CHANNEL_ID)
        if channel:
            if os.path.exists(IMAGE_PATH):
                with open(IMAGE_PATH, 'rb') as f:
                    file = discord.File(f, filename="image.png")
                    await channel.send(file=file)
                    
                    # Increment the message count and print timestamp + count
                    message_count += 1
                    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                    print(f"[{timestamp}] Message sent. Total count: {message_count}")
            else:
                print(f'Image file not found: {IMAGE_PATH}')
        else:
            print(f'Could not find channel with ID {CHANNEL_ID}')
    except Exception as e:
        print(f'Error sending message: {e}')

@client.event
async def on_message(message):
    if message.author == client.user:
        return

    if message.content.lower() == 'Message':
        await message.channel.send(file=discord.File(IMAGE_PATH))
        send_message.cancel()
        await client.close()

async def check_for_exit_key():
    while True:
        if keyboard.is_pressed('ctrl+x'):
            print("Ctrl + X detected, stopping...")
            send_message.cancel()
            await client.close()
            break
        await asyncio.sleep(0.1)

client.run(TOKEN)

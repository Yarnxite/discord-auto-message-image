import discord
from discord.ext import tasks
import logging
import asyncio
import keyboard

logging.basicConfig(level=logging.INFO)

# Replace with your Discord token
TOKEN = 'TOKEN'
# Replace with your Discord channel ID
CHANNEL_ID = 1234567890
# Replace with your  message
MESSAGE = "MESSAGE"

client = discord.Client()

@client.event
async def on_ready():
    print(f'Logged in as {client.user}')
    send_message.start()
    await check_for_exit_key()

@tasks.loop(seconds=130)
async def send_message():
    try:
        channel = client.get_channel(CHANNEL_ID)
        if channel:
            await channel.send(MESSAGE)
        else:
            print(f'Could not find channel with ID {CHANNEL_ID}')
    except Exception as e:
        print(f'Error sending message: {e}')

@client.event
async def on_message(message):
    if message.author == client.user:
        return

    if message.content.lower() == 'MESSAGE':
        await message.channel.send('message')
        send_message.cancel()
        await client.close()

async def check_for_exit_key():
    while True:
        # Detect if Ctrl + X is pressed
        if keyboard.is_pressed('ctrl+x'):
            print("Ctrl + X detected, stopping...")
            send_message.cancel()
            await client.close()
            break
        await asyncio.sleep(0.1)
client.run(TOKEN)

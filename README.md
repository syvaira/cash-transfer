# AgentWallet CASH Auto Transfer

This repository contains an automated Solana CASH transfer script and a GitHub Actions workflow that runs between 00:00 and 00:59 UTC every day.

## Files

- `auto_cash_transfer.sh` - Polls AgentWallet balances, detects new CASH, and sends it using the AgentWallet `contract-call` endpoint.
- `.github/workflows/auto_cash_transfer.yml` - Scheduled workflow that runs the script every 5 minutes during the 00:00 UTC hour.

## Setup

1. Add secrets to GitHub:
   - `AGENTWALLET_TOKEN`
   - `AGENTWALLET_DEST`
   - `AGENTWALLET_USERNAME`

2. Ensure the recipient has a CASH token account.

3. Use the manual workflow trigger or wait for the scheduled run.

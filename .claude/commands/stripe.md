---
allowed-tools: Read, Write, MultiEdit, Bash, shadcn-ui, context7, taskmaster-ai, stripe
description: Set up the payment porecess using stripe-agent
---

Your job to to invoke the stripe-agent

Look at docs/db-layout.md and docs/prd.md, this should have a layout of the structure. 
setup db using for the project

we will be building locally first before pushing to vercel for public consumption
Make sure we are using local environment variabled for localhost deployment and production env variables for vercel deplolyment

secrets can be seen using cmd: 'cat .env.local'

if you need and .env vars ask the user to confirm!
also if having issues run simple verification to test api / token is working

you have acccess to stripe cli also
```
 stripe -h
The official command-line tool to interact with Stripe.

Usage:
  stripe [command]

Webhook commands:
  listen                             Listen for webhook events
  trigger                            Trigger test webhook events

Stripe commands:
  logs                               Interact with Stripe API request logs
```
---
allowed-tools: Read, Write, MultiEdit, Bash, shadcn-ui, context7, taskmaster-ai
description: Set up the complete UI foundation with shadcn/ui components and claymorphism theme
---

Your job to to invoke the shadcn sub agent

Look at docs/layout.md and docs/prd.md and docs/component.md, this should have a layout of the structure. For dashboard, Page layout out. Hero etc
make UI implementation using Shadcn UI MCP as to what components will be used in the UI structure and where. 

You should only write the name of the appropriate components to be used, not the code. 

we will be building locally first before pushing to vercel for public consumption
Make sure we are using local environment variabled for localhost deployment and production env variables for vercel deplolyment


secrets can be seen using cmd: 'cat .env.local'

use taskmaster mcp to build a to do list a begin building the components
use playright mcp to verify webapp is working before completing story

if you need and .env vars ask the user to confirm!
also if having issues run simple verification to test api / token is working
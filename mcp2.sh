claude mcp add supabase -s local -e SUPABASE_ACCESS_TOKEN=${SUPABASE_ACCESS_TOKEN} -- npx -y @supabase/mcp-server-supabase@latest

npx @jpisnice/shadcn-ui-mcp-server --github-api-key ${GITHUB_TOKEN_SHADCN}

claude add mcp stripe -s local -e STRIPE_SECRET_KEY=${STRIPE_SECRET_KEY} -e STRIPE_PUBLISHABLE_KEY=${STRIPE_PUBLISHABLE_KEY} -- npx -y @stripe/mcp-server@latest
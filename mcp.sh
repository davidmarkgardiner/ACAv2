#!/bin/bash

set -e

echo "🚀 Installing MCP servers for Claude Desktop..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    print_error "This script is designed for macOS. Please adapt for your OS."
    exit 1
fi

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
    print_error "Node.js is not installed. Please install Node.js first."
    exit 1
fi

# Check if npm is installed
if ! command -v npm &> /dev/null; then
    print_error "npm is not installed. Please install npm first."
    exit 1
fi

# Check if teller is installed and available
if ! command -v teller &> /dev/null; then
    print_error "Teller is not installed. Please install teller first for secret management."
    exit 1
fi

print_status "Node.js version: $(node --version)"
print_status "npm version: $(npm --version)"

# Create MCP directory if it doesn't exist
MCP_DIR="$HOME/.mcp"
mkdir -p "$MCP_DIR"

print_status "Installing MCP servers..."

# Install MCP servers
print_status "Installing Playwright MCP server..."
npm install -g @playwright/mcp

print_status "Installing Brave Search MCP server..."
npm install -g @brave/brave-search-mcp-server

print_status "Installing shadcn UI MCP server..."
npm install -g @jpisnice/shadcn-ui-mcp-server

print_status "Installing TaskMaster AI MCP server..."
npm install -g @astrotask/mcp

# Note: Playwright browsers will be installed by the MCP server when needed

# Claude Desktop config directory
CLAUDE_CONFIG_DIR="$HOME/Library/Application Support/Claude"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Create Claude Desktop configuration
CLAUDE_CONFIG="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

print_status "Creating Claude Desktop configuration..."

# Use teller to inject secrets into the configuration
cat > "$CLAUDE_CONFIG" << 'EOF'
{
  "mcpServers": {
    "playwright": {
      "command": "node",
      "args": [
        "$(npm config get prefix)/lib/node_modules/@playwright/mcp/dist/index.js"
      ]
    },
    "shadcn-ui": {
      "command": "node",
      "args": [
        "$(npm config get prefix)/lib/node_modules/@jpisnice/shadcn-ui-mcp-server/dist/index.js"
      ]
    },
    "taskmaster-ai": {
      "command": "node",
      "args": [
        "$(npm config get prefix)/lib/node_modules/@astrotask/mcp/dist/index.js"
      ]
    },
    "brave-search": {
      "command": "node",
      "args": [
        "$(npm config get prefix)/lib/node_modules/@brave/brave-search-mcp-server/dist/index.js"
      ],
      "env": {
        "BRAVE_API_KEY": "{{ BRAVE_API_KEY }}"
      }
    },
    "elevenlabs": {
      "command": "npx",
      "args": [
        "@11labs/mcp-server"
      ],
      "env": {
        "ELEVEN_LABS_API_KEY": "{{ ELEVENLABS_API_KEY }}"
      }
    },
    "firecrawl": {
      "command": "npx",
      "args": [
        "@mendable/firecrawl-mcp-server"
      ],
      "env": {
        "FIRECRAWL_API_KEY": "{{ FIRECRAWL_API_KEY }}"
      }
    },
    "supabase": {
      "command": "npx",
      "args": [
        "@supabase/mcp-server"
      ],
      "env": {
        "SUPABASE_URL": "{{ SUPABASE_YOGA_PUBLIC_URL }}",
        "SUPABASE_ANON_KEY": "{{ PUBLIC_SUPABASE_ANON_KEY }}"
      }
    },
    "shadcn": {
      "command": "npx",
      "args": [
        "@shadcn/mcp-server"
      ]
    }
  }
}
EOF

# Create backup of original config before processing
if [ -f "$CLAUDE_CONFIG" ] && [ ! -f "$CLAUDE_CONFIG.backup" ]; then
    cp "$CLAUDE_CONFIG" "$CLAUDE_CONFIG.backup"
    print_success "Configuration backup created at $CLAUDE_CONFIG.backup"
elif [ -f "$CLAUDE_CONFIG.backup" ]; then
    print_warning "Backup already exists at $CLAUDE_CONFIG.backup"
fi

# Use teller to process the template and inject secrets
print_status "Injecting secrets using teller..."
if cat "$CLAUDE_CONFIG" | teller template > "${CLAUDE_CONFIG}.tmp"; then
    mv "${CLAUDE_CONFIG}.tmp" "$CLAUDE_CONFIG"
    print_success "Secrets injected successfully"
else
    print_error "Failed to inject secrets with teller. Please check your teller configuration."
    rm -f "${CLAUDE_CONFIG}.tmp"
    exit 1
fi

# Set proper permissions
chmod 600 "$CLAUDE_CONFIG"

print_success "MCP servers installation completed!"
echo ""
print_status "Configuration file created at: $CLAUDE_CONFIG"
print_status "Backup created at: $CLAUDE_CONFIG.backup"
echo ""
print_warning "Please restart Claude Desktop to load the new MCP servers."
echo ""
print_status "Installed MCP servers:"
echo "  - Playwright (web automation)"
echo "  - shadcn UI (UI components)"
echo "  - TaskMaster AI (task management)"
echo "  - Brave Search (web search)"
echo "  - ElevenLabs (text-to-speech)"
echo "  - Firecrawl (web scraping)"
echo "  - Supabase (database)"
echo ""
print_status "Make sure your teller configuration includes the following secrets:"
echo "  - brave-api-key (BRAVE_API_KEY)"
echo "  - elevenlabs-api-key (ELEVENLABS_API_KEY)"
echo "  - firecrawl-api (FIRECRAWL_API_KEY)"
echo "  - supabase-yoga-public-url (SUPABASE_URL)"
echo "  - public-supabase-anon-key (SUPABASE_ANON_KEY)"
echo ""
print_success "Installation complete! 🎉"
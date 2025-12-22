Here are the commands to install both tools on WSL:

## kubectl

```bash
# Download the latest stable version
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

# Install to /usr/local/bin
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Verify
kubectl version --client
```

## kubelogin (Azure AD auth)

```bash
# Download latest release
curl -LO "https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-amd64.zip"

# Extract and install
unzip kubelogin-linux-amd64.zip
sudo mv bin/linux_amd64/kubelogin /usr/local/bin/
sudo chmod +x /usr/local/bin/kubelogin

# Clean up
rm -rf kubelogin-linux-amd64.zip bin/

# Verify
kubelogin --version
```

## Quick one-liner alternative (if you have Azure CLI installed)

```bash
# Install kubelogin via az cli
az aks install-cli
```

This installs both kubectl and kubelogin in one go, though it puts them in `~/.azure-kubelogin/` by default.

Once installed, you can configure kubelogin for your AKS clusters with:
```bash
kubelogin convert-kubeconfig -l azurecli
```

Need me to cover anything else like shell completions or connecting to your AKS clusters?
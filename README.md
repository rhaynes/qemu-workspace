# qemu-workspace

Setup and management scripts for ubuntu running via qemu on mac

## What is this

This is a collection of QEMU helper scripts to run Ubuntu ARM64 VMs on Apple Silicon, with an isolated shared folder. It supports deep and thin clones
to create multiple isolated VMs or disposable VMs. QEMU's disk format only takes
up as much space as you write to it (not what you allocate), so these tend
to be lightweight. This really can be used for anything but it's aimed at
isolating agents.

## Usage

```
./install-qemu.sh # Installs using homebrew
./create-vm.sh    # interactive
```

After the vm's folder has been created

```
./start-vm.sh    <vm-folder>
```

(Optional) If you want multiple vm's based on the same image:

```
./clone-vm.sh    <source-folder> [dest-folder]
./thin-clone.sh  <source-folder> [dest-folder]
```

(Optional) Change the hostname if you've cloned to make it easier to keep track of things:

```
./rename-vm.sh vms/clone clone
```

The login prompt for ubuntu at the command line should appear.
At that point this will get you in.

```
./ssh-vm.sh      <vm-folder> [remote-command...]
```

```
sudo passwd ubuntu
sudo apt update
sudo apt upgrade
sudo apt install -y ubuntu-desktop-minimal
sudo systemctl set-default graphical.target
sudo reboot
```

Quick install for vscode:

```
sudo apt install -y wget gpg
wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor | sudo tee /etc/apt/keyrings/packages.microsoft.gpg >/dev/null
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
sudo apt update
sudo apt install -y code
```

Recommended vscode settings:

```
{
  "telemetry.telemetryLevel": "off",
  "chat.commandCenter.enabled": false,
  "chat.disableAIFeatures": true,
  "editor.inlineSuggest.enabled": false,
  "inlineChat.enabled": false,
  "github.copilot.enable": { "*": false },
  "workbench.enableExperiments": false,
  "extensions.autoCheckUpdates": false,
  "update.mode": "manual"
}
```

## Sharing files

All sharing between the host and the vm happens through `vms/${vm-name}/shared` on the host side and `/mnt/shared` on the vm side.

## Next steps

### For claude code

```
curl -fsSL https://claude.ai/install.sh | bash
claude --version
```

Install the vscode extension for Claude and log in.

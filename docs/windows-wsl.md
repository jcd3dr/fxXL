# 🪟 Windows 11 Setup Guide (via WSL + PowerShell)

Although `fx` was built natively for Unix environments (macOS and Linux) because of its Zig architecture, you can use it on Windows 11 in a fully transparent way.

With this setup you keep all your projects in your normal Windows folders (for example, `D:\dev\`) and run `fx` commands directly from PowerShell, with no need to move your files into the Linux virtual machine.

## Step 1: Install inside WSL

First, make sure WSL (Windows Subsystem for Linux) is enabled with your preferred distribution (such as Ubuntu). Open the WSL terminal and install `fx` using the official Linux method described in the [Install](../README.md#install) section of this repository.

## Step 2: Get the exact path to the binary

Inside your WSL terminal, run the following command to find out where the executable was installed:

```bash
which fx
```

You'll see a path on screen similar to this one: `/home/your_user/.local/bin/fx` (or similar). Copy that path in full.

## Step 3: Create a native function in PowerShell

To be able to call the program from Windows as if it were a native application, we'll create a permanent alias in your PowerShell profile.

1. Open PowerShell on Windows and run the following command to create and open your custom profile file:

```powershell
New-Item -Path $PROFILE -Type File -Force; notepad $PROFILE
```

2. In the Notepad window that opens, paste the following function (replacing the example path with the exact path you got in Step 2):

```powershell
function fx { wsl "/home/your_user/.local/bin/fx" $args }
```

3. Save the file (`Ctrl + S`) and close Notepad.

## Step 4: Enable script execution

For security, Windows 11 blocks loading custom profiles by default. To let your new function run, run this command in PowerShell:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

(When it asks if you're sure, press `Y` to confirm and then `Enter`).

## Step 5: Reload and you're done

To apply the changes without closing your current terminal, run:

```powershell
. $PROFILE
```

## 🚀 Daily workflow

That's it! Now you can navigate to any of your Windows drives or development folders and call the AI directly.

For example, if your projects live in `D:\dev`, just do:

```powershell
cd D:\dev\your-ai-project
fx --help
```

WSL handles the command behind the scenes at Zig's native speed, while it reads, analyzes, and edits the files that live safely on your Windows 11 file system.

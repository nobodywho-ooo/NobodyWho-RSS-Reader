
# NobodyWho RSS Reader

This is fork of [NetNewsWire](https://netnewswire.com/) is a free and open-source feed reader for macOS and iOS.

The macOS app has been modified and has an extra filtering feature, using Laya decision model with [NobodyWho](https://github.com/nobodywho-ooo/nobodywho) inference engine. Once you have downloaded the model, you can filter the news, either by removing ads or hide certain topics, or both.

# Download the app

Check the [release section](https://github.com/nobodywho-ooo/NobodyWho-RSS-Reader/releases) for the latest version available.

#### Building

You can build and test NetNewsWire without a paid developer account.

```bash
git clone https://github.com/Ranchero-Software/NetNewsWire.git
```

You can locally override the Xcode settings for code signing
by creating a `DeveloperSettings.xcconfig` file locally at the appropriate path.
This allows for a pristine project with code signing set up with the appropriate
developer ID and certificates, and for developer to be able to have local settings
without needing to check in anything into source control.

You can do this in one of two ways: using the included `setup.sh` script or by creating the folder structure and file manually.

##### Using `setup.sh`

- Open Terminal and `cd` into the NetNewsWire directory. 
- Run this command to ensure you have execution rights for the script: `chmod +x setup.sh`
- Execute the script with the following command: `./setup.sh` and complete the answers.

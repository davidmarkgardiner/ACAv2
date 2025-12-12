**🚨 Image Pull Failures in Dev - Root Cause Identified**

Hi team,

Quick explanation of why dev image pulls are failing:

**The setup:**
- Golden Path pushes to **Snapshot Nexus** - that's fine
- Dev clusters *could* pull directly from Snapshot Nexus - that would work

**What's going wrong:**
- Golden Path is configuring the image pull location to point at **Dev ACR**
- But there's no copy job moving images from Snapshot Nexus → Dev ACR
- So dev tries to pull from ACR... and the image isn't there

**In short:** They're telling us to pull from ACR, but nobody's putting the images in ACR.

**Options:**
1. Pull directly from Snapshot Nexus (no ACR involved), or
2. Set up a copy job from Snapshot Nexus → Dev ACR if they want to use ACR




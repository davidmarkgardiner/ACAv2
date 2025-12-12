
Hi Mark,

Thanks for the context - appreciate the clarification on scope.

But I think we're still missing something here. To put it simply:

**Users are pushing to Snapshot Nexus, but pulling from Main Nexus (container-registry) - and it works... eventually.**

That's like pushing to GHCR and pulling from Docker Hub. It shouldn't work. But it does - after a delay.

So *something* is copying images from Snapshot → Main Nexus. If it's not your job, and it's not ours, then who's doing it? Because users aren't imagining this - the images do appear in Main Nexus after ~30 mins or so.

Until we identify what's doing that copy, we can't properly advise users on the correct path or fix the documentation.

Happy to dig into this on the call.

Cheers,
Dave


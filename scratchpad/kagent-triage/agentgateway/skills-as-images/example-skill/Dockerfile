# Skill image — copies files into an empty scratch image.
# Final size is essentially the size of your SKILL.md + scripts (usually <10 KB).
#
# Build:
#   docker build -t gitea.internal/your-team/your-skill:v1 .
#
# Push:
#   docker push gitea.internal/your-team/your-skill:v1
#
# Reference from an Agent:
#   spec:
#     skills:
#       refs:
#         - gitea.internal/your-team/your-skill:v1
# ---
FROM scratch

# Everything under skill/ goes to / in the image.
# kagent's SkillsTool expects SKILL.md at the root of the mounted volume.
COPY skill/ /

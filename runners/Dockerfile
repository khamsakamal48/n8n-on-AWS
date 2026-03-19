# =============================================================================
# n8n Task Runners — Custom Image with Python Dependencies
# Based on: https://docs.n8n.io/hosting/configuration/task-runners/
# =============================================================================

FROM n8nio/runners:stable

USER root

# Install Python packages
RUN cd /opt/runners/task-runner-python && \
    uv pip install pandas numpy requests

# Install pizzip in the JS task runner directory
RUN cd /opt/runners/task-runner-javascript && \
    npx --yes npm install pizzip

# Copy custom task runners configuration
COPY n8n-task-runners.json /etc/n8n-task-runners.json

USER runner

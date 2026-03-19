# =============================================================================
# n8n Task Runners — Custom Image with Python Dependencies
# Based on: https://docs.n8n.io/hosting/configuration/task-runners/
# =============================================================================

# Stage 1: Install pizzip using a full Node image
FROM node:20-alpine AS builder
RUN mkdir /pizzip && cd /pizzip && npm init -y && npm install pizzip

# Stage 2: Actual runners image
FROM n8nio/runners:stable

USER root

# Install Python packages
RUN cd /opt/runners/task-runner-python && \
  uv pip install pandas numpy requests

# Copy pizzip from builder
COPY --from=builder /pizzip/node_modules /opt/runners/task-runner-javascript/node_modules

# Copy custom task runners configuration
COPY n8n-task-runners.json /etc/n8n-task-runners.json

USER runner

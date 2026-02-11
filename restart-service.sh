#!/bin/bash
# Safe restart wrapper for n8n services
# Handles cleanup of stopped containers before restarting to prevent name conflicts
# Usage: ./restart-service.sh [service1] [service2] ... OR ./restart-service.sh all

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Service to container name mapping
declare -A SERVICE_TO_CONTAINER=(
    ["postgres"]="n8n-postgres"
    ["redis"]="n8n-redis"
    ["n8n"]="n8n"
    ["n8n-runners"]="n8n-runners"
    ["docling"]="n8n-docling"
)

# All services in order
ALL_SERVICES=("postgres" "redis" "n8n" "n8n-runners" "docling")

# Function to print colored messages
print_info() {
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

# Function to check prerequisites
check_prerequisites() {
    # Check if podman is available
    if ! command -v podman &> /dev/null; then
        print_error "podman is not installed or not in PATH"
        exit 1
    fi

    # Check if podman-compose is available
    if ! command -v podman-compose &> /dev/null; then
        print_error "podman-compose is not installed or not in PATH"
        exit 1
    fi

    # Check if docker-compose.yml exists
    if [ ! -f "docker-compose.yml" ]; then
        print_error "docker-compose.yml not found. Please run this script from /opt/n8n-production"
        exit 1
    fi
}

# Function to get container state
get_container_state() {
    local container_name=$1
    podman ps -a --filter "name=^${container_name}$" --format "{{.State}}" 2>/dev/null || echo "absent"
}

# Function to cleanup stopped container
cleanup_stopped_container() {
    local container_name=$1
    local state=$(get_container_state "$container_name")

    if [[ "$state" == "exited" || "$state" == "stopped" ]]; then
        print_info "Removing stopped container: $container_name"
        if podman rm "$container_name" 2>/dev/null; then
            print_success "Removed: $container_name"
            return 0
        else
            print_warning "Failed to remove: $container_name"
            return 1
        fi
    elif [[ "$state" == "running" ]]; then
        print_info "Container $container_name is running, will be recreated by podman-compose"
        return 0
    else
        print_info "Container $container_name does not exist"
        return 0
    fi
}

# Function to restart specific service
restart_service() {
    local service_name=$1
    local container_name=${SERVICE_TO_CONTAINER[$service_name]}

    if [ -z "$container_name" ]; then
        print_error "Unknown service: $service_name"
        print_info "Valid services: ${!SERVICE_TO_CONTAINER[@]}"
        return 1
    fi

    print_info "Restarting service: $service_name (container: $container_name)"

    # Cleanup stopped container if exists
    cleanup_stopped_container "$container_name"

    # Restart using podman-compose
    print_info "Running: podman-compose up -d $service_name"
    if podman-compose up -d "$service_name"; then
        print_success "Service $service_name restarted successfully"
        return 0
    else
        print_error "Failed to restart service: $service_name"
        return 1
    fi
}

# Function to restart all services
restart_all() {
    print_info "Restarting all services in the stack"

    # Cleanup all stopped containers
    for service in "${ALL_SERVICES[@]}"; do
        container_name=${SERVICE_TO_CONTAINER[$service]}
        cleanup_stopped_container "$container_name"
    done

    # Restart all services
    print_info "Running: podman-compose up -d"
    if podman-compose up -d; then
        print_success "All services restarted successfully"
        return 0
    else
        print_error "Failed to restart services"
        return 1
    fi
}

# Function to show current status
show_status() {
    print_info "Current container status:"
    echo ""
    podman ps -a --filter "name=n8n" --format "table {{.Names}}\t{{.State}}\t{{.Status}}"
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [service1] [service2] ... OR $0 all

Safe restart wrapper for n8n services. Automatically cleans up stopped
containers before restarting to prevent Podman name conflict errors.

Arguments:
  all              Restart all services in the stack
  postgres         Restart PostgreSQL
  redis            Restart Redis
  n8n              Restart n8n main service
  n8n-runners      Restart n8n task runners
  docling          Restart Docling Serve

Examples:
  $0 n8n-runners              # Restart just the runners
  $0 n8n n8n-runners          # Restart n8n and runners
  $0 all                      # Restart entire stack

Options:
  -h, --help       Show this help message
  -s, --status     Show current container status

For more information, see PRODUCTION-DEPLOYMENT-GUIDE.md
EOF
}

# Main script
main() {
    # Parse arguments
    if [ $# -eq 0 ]; then
        print_error "No service specified"
        echo ""
        show_usage
        exit 1
    fi

    # Check for help flag
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi

    # Check for status flag
    if [[ "$1" == "-s" || "$1" == "--status" ]]; then
        check_prerequisites
        show_status
        exit 0
    fi

    # Check prerequisites
    check_prerequisites

    print_info "n8n Safe Restart Script"
    print_info "========================"
    echo ""

    # Handle "all" argument
    if [ "$1" == "all" ]; then
        restart_all
        exit $?
    fi

    # Restart specified services
    failed=0
    for service in "$@"; do
        if ! restart_service "$service"; then
            failed=1
        fi
        echo ""
    done

    if [ $failed -eq 0 ]; then
        print_success "All requested services restarted successfully"
        echo ""
        show_status
        exit 0
    else
        print_error "Some services failed to restart"
        echo ""
        show_status
        exit 1
    fi
}

# Run main function
main "$@"

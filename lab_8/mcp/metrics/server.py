from fastmcp import FastMCP

mcp = FastMCP("DevOps Metrics")

@mcp.tool()
def get_server_metrics(instance: str) -> dict:
    """Получить метрики CPU и RAM сервера."""
    if instance != "web-server-01":
        return {"error": "Server not found"}

    return {
        "instance": instance,
        "cpu_usage": 95,
        "memory_usage": 72,
        "status": "running"
    }

@mcp.tool()
def get_top_processes(instance: str) -> list:
    """Получить процессы с наибольшей загрузкой CPU."""
    if instance != "web-server-01":
        return [{"error": "Server not found"}]

    return [
        {"pid": 1245, "name": "python", "cpu": 83},
        {"pid": 890, "name": "nginx", "cpu": 7},
        {"pid": 342, "name": "systemd", "cpu": 1}
    ]

if __name__ == "__main__":
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=8000,
        path="/mcp"
    )
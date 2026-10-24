from fastmcp import FastMCP

mcp = FastMCP("DevOps Logs")

# Тестовые журналы приложения
LOGS = {
    "web-server-01": [
        "10:20:01 INFO nginx: Server started",
        "10:21:15 INFO api: Request received",
        "10:22:30 WARNING api: Response time increased",
        "10:23:10 ERROR worker: Background task running too long",
        "10:23:45 ERROR python: CPU-intensive task detected",
        "10:24:00 WARNING system: CPU usage above 90%"
    ]
}


@mcp.tool()
def get_service_logs(instance: str) -> list[str]:
    """Получить последние записи журнала сервера."""
    return LOGS.get(instance, ["Server not found"])


@mcp.tool()
def search_errors(instance: str) -> list[str]:
    """Найти ошибки в журналах сервера."""
    logs = LOGS.get(instance, [])
    return [
        log for log in logs
        if "ERROR" in log
    ]


if __name__ == "__main__":
    mcp.run(
        transport="http",
        host="0.0.0.0",
        port=8000,
        path="/mcp"
    )
#!/usr/bin/env python3
"""A fake ticket service: a local MCP server over stdio. Tickets go to the file given as its only argument."""
import json, sys

path = sys.argv[1]

TOOLS = [
    {"name": "list_tickets", "description": "List the tickets, optionally those matching a few words.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}}},
    {"name": "get_ticket", "description": "Read one ticket by id.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
    {"name": "create_ticket", "description": "Create a ticket with a title, a description and who it is for.",
     "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}, "description": {"type": "string"}, "assignee": {"type": "string"}}, "required": ["title"]}},
    {"name": "update_ticket", "description": "Update a ticket's title, description, assignee or status.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}, "title": {"type": "string"}, "description": {"type": "string"}, "assignee": {"type": "string"}, "status": {"type": "string"}}, "required": ["id"]}},
]


def load():
    try:
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def save(tickets):
    with open(path, "w") as f:
        for ticket in tickets:
            f.write(json.dumps(ticket) + "\n")


def call(name, args):
    tickets = load()
    if name == "list_tickets":
        words = (args.get("query") or "").lower().split()
        return [t for t in tickets if all(w in json.dumps(t).lower() for w in words)]
    if name == "get_ticket":
        return next((t for t in tickets if t["id"] == args.get("id")), {"error": "no such ticket"})
    if name == "create_ticket":
        ticket = {"id": len(tickets) + 1, "status": "open", **args}
        save(tickets + [ticket])
        return ticket
    if name == "update_ticket":
        for ticket in tickets:
            if ticket["id"] == args.get("id"):
                ticket.update(args)
                save(tickets)
                return ticket
        return {"error": "no such ticket"}
    return {"error": "no such tool"}


for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if "id" not in message:
        continue
    method, params = message.get("method"), message.get("params") or {}
    if method == "initialize":
        result = {"protocolVersion": params.get("protocolVersion", "2025-03-26"), "capabilities": {"tools": {}}, "serverInfo": {"name": "Tracker", "version": "1.0"}}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        output = call(params.get("name"), params.get("arguments") or {})
        result = {"content": [{"type": "text", "text": json.dumps(output)}], "isError": False}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)

#!/bin/bash
# require-action-node.sh
# Blocks Edit/Write tools if no recent deciduous node exists
# Exit code 2 = block the tool and show error to Claude

# Check if deciduous is initialized
if [ ! -d ".deciduous" ]; then
    exit 0
fi

DB_FILE=".deciduous/deciduous.db"

# No database = fresh project, allow
if [ ! -f "$DB_FILE" ]; then
    exit 0
fi

# Check if any nodes exist at all
node_count=$(deciduous nodes 2>/dev/null | grep -cE '^\d+' || echo "0")
if [ "$node_count" -eq 0 ] 2>/dev/null; then
    exit 0
fi

# Check modification time of the database file
# If it was modified in the last 15 minutes, a node was recently added
now=$(date +%s)
fifteen_min_ago=$((now - 900))

if [[ "$OSTYPE" == "darwin"* ]]; then
    db_mtime=$(stat -f %m "$DB_FILE" 2>/dev/null || echo "0")
else
    db_mtime=$(stat -c %Y "$DB_FILE" 2>/dev/null || echo "0")
fi

if [ "$db_mtime" -gt "$fifteen_min_ago" ]; then
    exit 0
fi

# DB is stale - block and provide guidance
cat >&2 << 'EOF'
+===================================================================+
|  DECIDUOUS: No recent action/goal node found (>15 min stale)      |
+===================================================================+
|  Before editing files, log what you're about to do:               |
|                                                                   |
|  For new work:                                                    |
|    deciduous add goal "What you're trying to achieve" -c 90       |
|                                                                   |
|  For implementation:                                              |
|    deciduous add action "What you're about to implement" -c 85    |
|                                                                   |
|  Then link to parent:                                             |
|    deciduous link <parent_id> <new_id> -r "reason"                |
+===================================================================+
EOF

exit 2

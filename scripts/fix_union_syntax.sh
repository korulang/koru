#!/bin/bash

# Script to fix union constructor syntax in .kz files
# Changes: return .branch(.{...}) -> return .{ .@"branch" = .{...} };

echo "Fixing union constructor syntax in .kz files..."

# Find all .kz files with the wrong pattern
files=$(find . -name "*.kz" -type f | xargs grep -l "return \.[a-zA-Z_][a-zA-Z0-9_]*(")

if [ -z "$files" ]; then
    echo "No files need fixing!"
    exit 0
fi

echo "Files to fix:"
echo "$files"
echo ""

for file in $files; do
    echo "Fixing: $file"
    
    # Create backup
    cp "$file" "$file.bak"
    
    # Fix the pattern using sed
    # Pattern: return .branch(...) -> return .{ .@"branch" = ... }
    sed -i '' -E 's/return \.([a-zA-Z_][a-zA-Z0-9_]*)\((.*)\);/return .{ .@"\1" = \2 };/g' "$file"
    
    # Remove backup if successful
    if [ $? -eq 0 ]; then
        rm "$file.bak"
        echo "  ✅ Fixed"
    else
        mv "$file.bak" "$file"
        echo "  ❌ Failed, restored backup"
    fi
done

echo ""
echo "Done! Run integration tests to verify the fixes."
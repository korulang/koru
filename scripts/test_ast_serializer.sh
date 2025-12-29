#!/bin/bash
zig test test/test_ast_serializer.zig \
    --dep parser --dep ast --dep ast_serializer --dep lexer --dep errors --dep type_registry \
    -Mparser=src/parser.zig \
    -Mast=src/ast.zig \
    -Mast_serializer=src/ast_serializer.zig \
    -Mlexer=src/lexer.zig \
    -Merrors=src/errors.zig \
    -Mtype_registry=src/type_registry.zig \
    -ODebug --dep ast --dep lexer --dep errors --dep type_registry \
    -ODebug --dep ast
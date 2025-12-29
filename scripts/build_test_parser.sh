#!/bin/bash
zig test test/test_parser.zig \
    --dep parser --dep ast --dep lexer --dep errors --dep type_registry \
    -ODebug --dep ast --dep lexer --dep errors --dep type_registry -Mparser=src/parser.zig \
    -ODebug -Mast=src/ast.zig \
    -ODebug -Mlexer=src/lexer.zig \
    -ODebug -Merrors=src/errors.zig \
    -ODebug --dep ast -Mtype_registry=src/type_registry.zig
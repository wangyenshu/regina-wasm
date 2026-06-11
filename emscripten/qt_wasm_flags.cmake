if(EMSCRIPTEN)
    set_property(TARGET regina-gui APPEND_STRING PROPERTY LINK_FLAGS " -lembind -Wl,--allow-undefined -sERROR_ON_UNDEFINED_SYMBOLS=0 -sWARN_ON_UNDEFINED_SYMBOLS=0 ")
endif()
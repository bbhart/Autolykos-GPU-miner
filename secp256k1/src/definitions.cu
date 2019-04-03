// definitions.cu

/*******************************************************************************

    DEFINITIONS -- Constants, Structs and Macros

*******************************************************************************/

#include "../include/definitions.h"
#include "../include/jsmn.h"
#include <stddef.h>

////////////////////////////////////////////////////////////////////////////////
//  Initialize JSON string
////////////////////////////////////////////////////////////////////////////////
json_t::json_t(
    const int strlen,
    const int toklen
)
{
    cap = strlen? strlen + 1: JSON_CAPACITY + 1;
    len = strlen;

    FUNCTION_CALL(ptr, (char *)malloc(cap), ERROR_ALLOC);

    ptr[len] = '\0';

    FUNCTION_CALL(
        toks, (jsmntok_t *)malloc(toklen * sizeof(jsmntok_t)), ERROR_ALLOC
    );

    return;
}

////////////////////////////////////////////////////////////////////////////////
//  Initialize JSON string with other JSON string
////////////////////////////////////////////////////////////////////////////////
json_t::json_t(
    const json_t & newjson
)
{
    cap = newjson.cap;
    len = newjson.len;

    FREE(ptr);
    ptr = newjson.ptr;

    FREE(toks);
    toks = newjson.toks;

    return;
}

////////////////////////////////////////////////////////////////////////////////
//  Delete JSON string
////////////////////////////////////////////////////////////////////////////////
json_t::~json_t(
    void
)
{
    FREE(ptr);
    FREE(toks);

    return;
}

// definitions.cu

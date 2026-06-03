# MCP Schema Types
@enum Role user assistant
@enum LoggingLevel debug info notice warning error critical alert emergency
const RequestId = Union{String, Int}
const ProgressToken = Union{String, Int}

# ============================================================================
# Annotations & Resource Contents
# ============================================================================
struct Annotations
	audience::Union{Vector{String}, Nothing}
	priority::Union{Float64, Nothing}
	
	function Annotations(; audience=nothing, priority=nothing)
		# Validate priority if provided
		if priority !== nothing && !(0.0 <= priority <= 1.0)
			@warn "Priority should be between 0.0 and 1.0, got $priority"
			priority = max(0.0, min(1.0, priority))
		end
		new(audience, priority)
	end
end

# Add constructor for Annotations from Dict with validation
function Annotations(annotations_data::Dict{String, T}) where T
	audience = get(annotations_data, "audience", nothing)
	priority = get(annotations_data, "priority", nothing)
	
	# Validate audience if provided
	if audience !== nothing && !isa(audience, Vector{String})
		@warn "Audience should be a Vector{String}, got $(typeof(audience))"
		audience = nothing
	end
	
	return Annotations(; audience, priority)
end

abstract type ResourceContents end
struct TextResourceContents <: ResourceContents
	uri::String
	mimeType::Union{String, Nothing}
	text::String
end
struct BlobResourceContents <: ResourceContents
	uri::String
	mimeType::Union{String, Nothing}
	blob::String  # Base64-encoded
end

# ============================================================================
# Content Types
# ============================================================================
abstract type Content end

@kwdef struct TextContent <: Content
	type::String = "text"
	text::String
	annotations::Union{Annotations, Nothing} = nothing
end

# Add constructor for TextContent from Dict
function TextContent(content_data::Dict{String, T}) where T
	annotations = haskey(content_data, "annotations") && content_data["annotations"] !== nothing ? Annotations(content_data["annotations"]) : nothing
	return TextContent(
		type = get(content_data, "type", "text"),
		text = content_data["text"],
		annotations = annotations
	)
end

# Helper function to format base64 data for display
function format_data_url(data::AbstractString, mimeType::AbstractString, content_type::AbstractString)::String
    # If it already has the data URL prefix, return as is
    if startswith(data, "data:")
        return data
    end
    
    # If it's raw base64 data, add the proper prefix
    if !isempty(mimeType)
        return "data:$(mimeType);base64,$(data)"
    end
    
    # Fallback based on content type
    fallback_mime = content_type == "image" ? "image/png" : "audio/wav"
    return "data:$(fallback_mime);base64,$(data)"
end

@kwdef struct ImageContent <: Content
	type::String = "image"
	data::String  # Base64-encoded image data
	mimeType::String
	annotations::Union{Annotations, Nothing} = nothing
	
	# Inner constructor to format data URL
	function ImageContent(type, data, mimeType, annotations)
		formatted_data = format_data_url(data, mimeType, "image")
		new(type, formatted_data, mimeType, annotations)
	end
end

@kwdef struct AudioContent <: Content
	type::String = "audio"
	data::String  # Base64-encoded audio data
	mimeType::String
	annotations::Union{Annotations, Nothing} = nothing
	
	# Inner constructor to format data URL
	function AudioContent(type, data, mimeType, annotations)
		formatted_data = format_data_url(data, mimeType, "audio")
		new(type, formatted_data, mimeType, annotations)
	end
end

@kwdef struct EmbeddedResource <: Content
	type::String = "resource"
	resource::Union{TextResourceContents, BlobResourceContents}
	annotations::Union{Annotations, Nothing} = nothing
end

@kwdef struct CallToolResult
	content::Vector{Content} = Content[]
	isError::Union{Bool, Nothing} = nothing
	_meta::Union{Dict{String,Any}, Nothing} = nothing
end

# ============================================================================
# Content Parsing
# ============================================================================
parse_content(data) = TextContent(text = string(data))  # Fallback for non-dict

function parse_content(data::Dict{String, T}) where T
    content_type = get(data, "type", "text")
    
    if content_type == "text"         return TextContent(data)
    elseif content_type == "image"    return parse_image_content(data)
    elseif content_type == "audio"    return parse_audio_content(data)
    elseif content_type == "resource" return parse_embedded_resource(data)
    else
        @warn "Unknown content type: $content_type, falling back to text"
        return TextContent(text = string(data))
    end
end

# Specialized parsing functions - shared logic for binary content types
function parse_binary_content(::Type{T}, data::Dict{String, V}) where {T, V}
    annotations = get(data, "annotations", nothing)
    annotations !== nothing && (annotations = Annotations(annotations))
    return T(data = get(data, "data", ""), mimeType = get(data, "mimeType", ""), annotations = annotations)
end

parse_image_content(data::Dict{String, T}) where T = parse_binary_content(ImageContent, data)
parse_audio_content(data::Dict{String, T}) where T = parse_binary_content(AudioContent, data)

function parse_embedded_resource(data::Dict{String, T}) where T
    resource_data = data["resource"]
    resource = if haskey(resource_data, "text")
        TextResourceContents(
            resource_data["uri"],
            get(resource_data, "mimeType", nothing),
            resource_data["text"]
        )
    else
        BlobResourceContents(
            resource_data["uri"],
            get(resource_data, "mimeType", nothing),
            resource_data["blob"]
        )
    end
    
    annotations = get(data, "annotations", nothing)
    annotations !== nothing && (annotations = Annotations(annotations))
    return EmbeddedResource(resource = resource, annotations = annotations)
end

# Safe content parsing with error handling
function safe_parse_content(data::Any)
    try
        return parse_content(data)
    catch e
        @warn "Failed to parse content" exception=e data=data
        return TextContent(text = "Parse error: $(string(data))")
    end
end

# Improved result content parsing with multiple dispatch
function parse_result_content(result::Dict{String, T})::Vector{Content} where T
    if haskey(result, "content") && isa(result["content"], Vector)
        return [safe_parse_content(item) for item in result["content"]]
    else
        # Fallback for unexpected format
        return [TextContent(text = JSON.json(result))]
    end
end

function parse_result_content(result::String)::Vector{Content}
    # Handle complex string format like "[TextContent(...), ImageContent(...)]"
    if startswith(result, "[") && endswith(result, "]")
        # Try to parse as structured content string (fallback for legacy formats)
        parsed_content = parse_content_string_fallback(result)
        return isempty(parsed_content) ? [TextContent(text = result)] : parsed_content
    else
        # Simple string result
        return [TextContent(text = result)]
    end
end

function parse_result_content(result::Vector)::Vector{Content}
    return [safe_parse_content(item) for item in result]
end

# Fallback for any other type
parse_result_content(result::Any)::Vector{Content} = [TextContent(text = string(result))]

# Helper to unescape captured text
unescape_text(s) = replace(s, "\\'" => "'", "\\\"" => "\"", "\\n" => "\n", "\\r" => "\r", "\\t" => "\t")

# Legacy string parsing fallback (improved regex patterns)
function parse_content_string_fallback(content_str::String)::Vector{Content}
    contents = Content[]
    
    if occursin("TextContent", content_str)
        # Try single quotes first, then double quotes
        text_pattern = r"TextContent\([^)]*text='((?:[^'\\]|\\.)*)'"
        text_matches = collect(eachmatch(text_pattern, content_str))
        isempty(text_matches) && (text_matches = collect(eachmatch(r"TextContent\([^)]*text=\"((?:[^\"\\]|\\.)*)\"", content_str)))
        for m in text_matches
            push!(contents, TextContent(; text = unescape_text(m.captures[1])))
        end
    end
    
    # Improved pattern matching for ImageContent
    if occursin("ImageContent", content_str)
        # Extract image content with better pattern matching
        data_pattern = r"data='([^']+)'"
        mime_pattern = r"mimeType='([^']+)'"
        
        # Find ImageContent blocks
        image_blocks = eachmatch(r"ImageContent\([^)]+\)", content_str)
        for block in image_blocks
            block_str = block.match
            data_match = match(data_pattern, block_str)
            mime_match = match(mime_pattern, block_str)
            
            if data_match !== nothing && mime_match !== nothing
                push!(contents, ImageContent(
                    data = data_match.captures[1],
                    mimeType = mime_match.captures[1]
                ))
            end
        end
    end
    
    return contents
end

# Improved CallToolResult constructor
function CallToolResult(result_data::Dict{String, T}) where T
    content = if haskey(result_data, "content") && result_data["content"] !== nothing
        parse_result_content(result_data["content"])
    elseif haskey(result_data, "result_json") && result_data["result_json"] !== nothing
        result_json = result_data["result_json"]
        isa(result_json, Vector) ? [parse_content(item) for item in result_json] : [TextContent(text = string(result_json))]
    else
        parse_result_content(get(result_data, "result", result_data))
    end
    
    CallToolResult(content = content, isError = get(result_data, "isError", false), _meta = get(result_data, "_meta", nothing))
end

# Validation functions
validate_content(c::TextContent) = (isempty(c.text) && throw(ArgumentError("TextContent text cannot be empty")); true)
validate_content(c::Union{ImageContent, AudioContent}) = begin
    isempty(c.data) && throw(ArgumentError("$(typeof(c)) data cannot be empty"))
    isempty(c.mimeType) && throw(ArgumentError("$(typeof(c)) mimeType cannot be empty"))
    true
end

# Dispatch-based result2string for different content types
mcp_result2string(content::TextContent)::String = content.text
mcp_result2string(content::Union{ImageContent, AudioContent, EmbeddedResource})::Union{String, Nothing} = nothing

# CallToolResult formatting - only concatenate non-nothing text results
function mcp_result2string(result::Union{CallToolResult, Nothing})::String
    result === nothing && return "No result"
    join(filter(!isnothing, [mcp_result2string(c) for c in result.content]), "\n")
end


# Extract base64 data from MCP tool results by content type
mcp_result2base64(::Type{T}, tool::CallToolResult) where T <: Content = [c.data for c in tool.content if isa(c, T)]

mcp_resultimg2base64(tool::CallToolResult) = mcp_result2base64(ImageContent, tool)
mcp_resultaudio2base64(tool::CallToolResult) = mcp_result2base64(AudioContent, tool)

# ============================================================================
# Tool Types
# ============================================================================
abstract type AbstractMCPTool end

struct InputSchema
	type::String  # Always "object" for MCP tools
	properties::Union{Dict{String,Any}, Nothing}
	required::Union{Vector{String}, Nothing}
	schema::Union{String, Nothing}
	additionalProperties::Union{Bool, Nothing}
	
end
# Constructor that enforces type = "object"
InputSchema(properties::Dict{String, T}, required::Vector{String}) where T = InputSchema("object", properties, required, nothing, nothing)
InputSchema(type::String, properties::Dict{String, T}, required::Vector{String}) where T = begin
	type != "object" && @warn "InputSchema type should be 'object' for MCP tools, got '$type'"
	InputSchema(type, properties, required, nothing, nothing)
end
InputSchema(data::Dict) = begin
	schema = get(data, "\$schema", nothing)
	type = data["type"]
	properties = get(data, "properties", nothing)
	required = get(data, "required", nothing)
	additionalProperties = get(data, "additionalProperties", nothing)
	
	InputSchema(type, properties, required, schema, additionalProperties)
end

# Tool annotations based on MCP schema
struct ToolAnnotations
	title::Union{String, Nothing}
	readOnlyHint::Union{Bool, Nothing}
	destructiveHint::Union{Bool, Nothing}
	idempotentHint::Union{Bool, Nothing}
	openWorldHint::Union{Bool, Nothing}
	
	function ToolAnnotations(; title=nothing, readOnlyHint=nothing, destructiveHint=nothing, 
						   idempotentHint=nothing, openWorldHint=nothing)
		# Validate hints if provided
		if readOnlyHint !== nothing && destructiveHint !== nothing && readOnlyHint && destructiveHint
			@warn "Tool cannot be both readOnly and destructive"
			destructiveHint = false
		end
		new(title, readOnlyHint, destructiveHint, idempotentHint, openWorldHint)
	end
end

# Enhanced constructor for ToolAnnotations from Dict with validation
ToolAnnotations(d::Dict{String, T}) where T = ToolAnnotations(;
    title = get(d, "title", nothing), readOnlyHint = get(d, "readOnlyHint", nothing),
    destructiveHint = get(d, "destructiveHint", nothing), idempotentHint = get(d, "idempotentHint", nothing),
    openWorldHint = get(d, "openWorldHint", nothing))

struct MCPToolSpecification <: AbstractMCPTool
	server_id::String # TODO WE ACTUALLY don't have this data???

	name::String
	description::Union{String, Nothing}
	input_schema::InputSchema
	annotations::Union{ToolAnnotations, Nothing}
	env::Dict{String, Any}
end

# Constructor for MCPToolSpecification from tool dictionary
MCPToolSpecification(server_id::String, tool_dict::Dict{String, T}, env::Union{Dict{String, T2}, Nothing}) where {T, T2} = begin
	name = tool_dict["name"]
	description = get(tool_dict, "description", nothing)
	input_schema = InputSchema(tool_dict["inputSchema"])
	
	# Parse annotations if present
	annotations = if haskey(tool_dict, "annotations") && tool_dict["annotations"] !== nothing
		ToolAnnotations(tool_dict["annotations"])
	else
		nothing
	end
	final_env = env === nothing ? Dict{String, Any}() : Dict{String, Any}(env)

	MCPToolSpecification(server_id, name, description, input_schema, annotations, final_env)
end

@kwdef struct Resource
	uri::String
	name::String
	description::Union{String, Nothing} = nothing
	mimeType::Union{String, Nothing} = nothing
	annotations::Union{Annotations, Nothing} = nothing
	size::Union{Int, Nothing} = nothing
end

# ============================================================================
# JSON-RPC Types
# ============================================================================
@kwdef struct JSONRPCRequest
	jsonrpc::String = "2.0"
	id::RequestId
	method::String
	params::Union{Dict{String,Any}, Nothing} = nothing
end

@kwdef struct JSONRPCResponse
	jsonrpc::String = "2.0"
	id::RequestId
	result::Union{Dict{String,Any}, Nothing} = nothing
end

@kwdef struct JSONRPCError
	jsonrpc::String = "2.0"
	id::RequestId
	error::Dict{String,Any}
end


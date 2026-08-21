
[[vk::binding(0, 0)]]
Sampler2D[256] textures;

struct Vertex {
  float2 position;
  float2 uv;
  float4 color;
  uint texture_id;
};

struct PushConstant {
  Vertex *vertices;
  float2 screen_size;
};

[[vk::push_constant]]
PushConstant pc;

struct VertexOutput {
  float4 position : SV_Position;
  float4 color : COLOR0;
  float2 uv : TEXCOORD0;
  nointerpolation uint texture_index : TEXCOORD1;
};

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
  Vertex vertex = pc.vertices[vertex_index];
  VertexOutput output;
  output.position = float4(vertex.position / pc.screen_size * 2 - 1, 0, 1.0);
  output.color = vertex.color;
  output.uv = vertex.uv;
  output.texture_index = vertex.texture_id;
  return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target {
  float4 texel =
      textures[NonUniformResourceIndex(input.texture_index)].Sample(input.uv);
  return input.color * texel;
}

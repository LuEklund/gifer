

struct Vertex {
  float3 position;
  float _;
  float4 color;
};

struct PushConstant {
  Vertex *vertices;
};

[[vk::push_constant]]
PushConstant pc;

struct VertexOutput {
  float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
  VertexOutput output;
  output.position = float4(pc.vertices[vertex_index].position, 1.0);
  return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target { return input.position; }


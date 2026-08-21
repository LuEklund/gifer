

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
  float4 color : COLOR0;
};

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
  Vertex vertex = pc.vertices[vertex_index];
  VertexOutput output;
  output.position = float4(vertex.position, 1.0);
  output.color = vertex.color;
  return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target { return input.color; }


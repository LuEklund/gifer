
// struct VertexInput {
//     float3 postion : POSITION;
// };

struct VertexOutput {
  float4 position : SV_Position;
};
// float3 vertices[3] = {
//     float3
// };

[shader("vertex")]
VertexOutput vertex(uint vertex_index: SV_VertexID) {
  float2 corner = float2((vertex_index << 1) & 2, vertex_index & 2);
  VertexOutput output;
  float2 ndc = corner * 2.0 - 1.0;
  output.position = float4(ndc * 0.2, 0, 1.0);
  return output;
}

[shader("fragment")]
float4 fragment(VertexOutput input) : SV_Target { return input.position; }

 

  

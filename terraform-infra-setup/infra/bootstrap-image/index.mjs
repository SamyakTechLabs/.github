export const handler = async () => ({
  statusCode: 200,
  headers: {
    "content-type": "application/json"
  },
  body: JSON.stringify({
    ok: true,
    message: "Infrastructure is ready. Replace this image from CI."
  })
});

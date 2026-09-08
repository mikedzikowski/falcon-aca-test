# Simple web server for testing Falcon Container Security
FROM nginx:alpine

# Add a simple index page
RUN echo '<html><body><h1>🛡️ Falcon Container Security Demo</h1><p>This container has been patched with CrowdStrike Falcon sensor for runtime protection.</p></body></html>' > /usr/share/nginx/html/index.html

# Expose port 80
EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
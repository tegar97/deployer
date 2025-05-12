FROM node:18-alpine

WORKDIR /app

COPY package*.json ./

RUN npm install --production

COPY server.js ./

# Create scripts directory 
RUN mkdir -p /scripts
COPY deploy.sh /scripts/deploy.sh
RUN chmod +x /scripts/deploy.sh


COPY manifests/ /scripts/manifests/

# Install bash for script execution
RUN apk add --no-cache bash

EXPOSE 9999

ENV NODE_ENV=production
ENV PORT=9999

CMD ["node", "server.js"]

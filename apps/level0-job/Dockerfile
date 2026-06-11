FROM node:20-alpine

WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY src ./src
COPY data ./data

CMD ["npm", "start"]

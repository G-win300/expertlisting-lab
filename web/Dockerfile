FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/
ARG APP_VERSION=dev
RUN echo "${APP_VERSION}" > /usr/share/nginx/html/version.txt
EXPOSE 80

package LTI1p3::Lti1p3Router;

use Mojo::Base -strict, -signatures;

sub setup ($router) {
	my $lti1p3Router = $router->any('/lti1p3')
							  ->to(namespace => 'LTI1p3::Entrypoint');
	$lti1p3Router->options('/login')
				 ->to(controller => 'Login', action => 'options');
	$lti1p3Router->any(['GET', 'POST'] => '/login')
				 ->to(controller => 'Login', action => 'run')
				 ->name('lti1p3login');
	$lti1p3Router->options('/redirect')
				 ->to(controller => 'Launch', action => 'options');
	$lti1p3Router->any(['GET', 'POST'] => '/redirect')
				 ->to(controller => 'Launch', action => 'run')
				 ->name('lti1p3redirect');
}

1;
